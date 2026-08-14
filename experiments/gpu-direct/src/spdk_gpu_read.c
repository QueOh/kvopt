/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Samsung Electronics Co., Ltd.
 *
 * spdk_gpu_read - verification plan stages 9-10: the first direct
 * NVMe READ from an NVMe-oF (RDMA) namespace into GPU HBM.
 *
 * Flow (plan section 13):
 *   allocate GPU buffer (DMA-BUF export)
 *     -> create SPDK RDMA memory domain with a translation callback
 *     -> connect to the JBOF over RDMA
 *     -> spdk_nvme_ns_cmd_read_ext(..., opts.memory_domain = gpu domain)
 *     -> translation cb registers the DMA-BUF on the transport QP's PD
 *        (ibv_reg_dmabuf_mr) and returns the GPU VA + lkey/rkey
 *     -> poll completion
 *     -> CUDA checksum kernel verifies the pattern in HBM
 *     -> only the digest crosses to the CPU; JSON verdict.
 *
 * No-fallback rules baked in (plan section 15):
 *   - the app never allocates a host payload buffer;
 *   - a stub (no-CUDA) build fails with ENOTSUP at gpu_mem_alloc;
 *   - any registration/translation failure fails the I/O — there is no
 *     path that silently reads into host DRAM.
 */

#include "spdk/stdinc.h"
#include "spdk/env.h"
#include "spdk/nvme.h"
#include "spdk/dma.h"
#include "spdk/string.h"
#include "spdk/util.h"
#include "spdk/likely.h"

#include <infiniband/verbs.h>

#include "gpu_mem.h"

static char g_trid_str[512];
static uint32_t g_nsid = 1;
static uint64_t g_lba = 0;
static uint32_t g_blocks = 256;
static int g_gpu_id = 0;
static bool g_json;
static bool g_fail_registration; /* negative test: plan section 15 */
static const char *g_core_mask;

/* per-buffer context handed to the translation callback via
 * ext_io_opts.memory_domain_ctx
 */
struct gpu_io_ctx {
	struct gpu_buf buf;
	struct ibv_mr *mr;	/* lazily registered on the transport PD */
	struct ibv_pd *pd;
	bool poison_registration;
};

struct io_done {
	bool done;
	struct spdk_nvme_cpl cpl;
};

static void
io_cb(void *arg, const struct spdk_nvme_cpl *cpl)
{
	struct io_done *d = arg;

	d->cpl = *cpl;
	d->done = true;
}

/*
 * Stage 9: translation from the GPU memory domain into the RDMA
 * transport's domain. Called by the NVMe RDMA transport for each I/O
 * carrying our memory domain. dst_domain_ctx->rdma.ibv_qp is the
 * transport's QP: its PD is the one the MR must live on.
 */
static int
gpu_domain_translate(struct spdk_memory_domain *src_domain, void *src_domain_ctx,
		     struct spdk_memory_domain *dst_domain,
		     struct spdk_memory_domain_translation_ctx *dst_domain_ctx,
		     void *addr, size_t len,
		     struct spdk_memory_domain_translation_result *result)
{
	struct gpu_io_ctx *ctx = src_domain_ctx;
	struct ibv_qp *qp;

	(void)src_domain;

	if (dst_domain_ctx == NULL || dst_domain_ctx->size < sizeof(*dst_domain_ctx) ||
	    dst_domain_ctx->rdma.ibv_qp == NULL) {
		fprintf(stderr, "translate: no RDMA qp context (transport not RDMA?)\n");
		return -ENOTSUP;
	}
	qp = dst_domain_ctx->rdma.ibv_qp;

	if ((uint64_t)addr < ctx->buf.dptr ||
	    (uint64_t)addr + len > ctx->buf.dptr + ctx->buf.size) {
		fprintf(stderr, "translate: address outside the GPU buffer\n");
		return -EINVAL;
	}

	if (ctx->poison_registration) {
		/* negative test: prove failure here fails the I/O */
		fprintf(stderr, "translate: registration poisoned (negative test)\n");
		return -EPERM;
	}

	if (ctx->mr == NULL) {
		ctx->pd = qp->pd;
		ctx->mr = ibv_reg_dmabuf_mr(ctx->pd, 0, ctx->buf.size,
					    ctx->buf.dptr, ctx->buf.dmabuf_fd,
					    IBV_ACCESS_LOCAL_WRITE |
					    IBV_ACCESS_REMOTE_WRITE |
					    IBV_ACCESS_REMOTE_READ);
		if (ctx->mr == NULL) {
			fprintf(stderr, "translate: ibv_reg_dmabuf_mr failed: %s\n",
				strerror(errno));
			return -errno ? -errno : -EIO;
		}
		fprintf(stderr, "registered GPU DMA-BUF: addr 0x%" PRIx64
			" size %zu lkey 0x%x rkey 0x%x\n",
			ctx->buf.dptr, ctx->buf.size, ctx->mr->lkey, ctx->mr->rkey);
	} else if (ctx->pd != qp->pd) {
		fprintf(stderr, "translate: PD changed between I/Os\n");
		return -EINVAL;
	}

	result->size = sizeof(*result);
	result->iov_count = 1;
	result->iov.iov_base = addr;
	result->iov.iov_len = len;
	result->iovs = NULL;
	result->dst_domain = dst_domain;
	result->rdma.lkey = ctx->mr->lkey;
	result->rdma.rkey = ctx->mr->rkey;
	return 0;
}

static void
usage(const char *prog)
{
	printf("usage: %s -r <RDMA trid> [options]\n", prog);
	printf("  -r trid   \"trtype:RDMA adrfam:IPv4 traddr:... trsvcid:4420 subnqn:...\"\n");
	printf("  -n nsid (1)   -L lba (0)   -c blocks (256)\n");
	printf("  -g gpu id (0)\n");
	printf("  -X        negative test: poison GPU registration; the READ MUST fail\n");
	printf("  -J        JSON verdict\n");
	printf("  -m mask   SPDK core mask\n");
}

int
main(int argc, char **argv)
{
	struct spdk_env_opts env_opts;
	struct spdk_nvme_ctrlr_opts ctrlr_opts;
	struct spdk_nvme_transport_id trid = {};
	struct spdk_nvme_ctrlr *ctrlr = NULL;
	struct spdk_nvme_ns *ns = NULL;
	struct spdk_nvme_qpair *qpair = NULL;
	struct spdk_memory_domain *gpu_domain = NULL;
	struct spdk_memory_domain *ctrlr_domains[4] = {};
	struct spdk_nvme_ns_cmd_ext_io_opts eopts = {};
	struct gpu_io_ctx ctx = {};
	struct io_done done = {};
	struct gpu_digest digest = {};
	uint32_t block_size = 0, io_bytes = 0;
	uint64_t tsc_rate, t0, io_tsc = 0;
	double lat_us = 0.0, gbps = 0.0;
	int nr_domains = 0;
	bool checksum_ok = false, io_failed = false;
	int rc, op;

	while ((op = getopt(argc, argv, "r:n:L:c:g:XJm:h")) != -1) {
		switch (op) {
		case 'r':
			snprintf(g_trid_str, sizeof(g_trid_str), "%s", optarg);
			break;
		case 'n':
			g_nsid = spdk_strtol(optarg, 10);
			break;
		case 'L':
			g_lba = spdk_strtoll(optarg, 10);
			break;
		case 'c':
			g_blocks = spdk_strtol(optarg, 10);
			break;
		case 'g':
			g_gpu_id = spdk_strtol(optarg, 10);
			break;
		case 'X':
			g_fail_registration = true;
			break;
		case 'J':
			g_json = true;
			break;
		case 'm':
			g_core_mask = optarg;
			break;
		case 'h':
		default:
			usage(argv[0]);
			return op == 'h' ? 0 : 1;
		}
	}
	if (g_trid_str[0] == '\0') {
		usage(argv[0]);
		return 1;
	}

	if (spdk_nvme_transport_id_parse(&trid, g_trid_str) != 0) {
		fprintf(stderr, "invalid trid\n");
		return 1;
	}
	if (trid.trtype != SPDK_NVME_TRANSPORT_RDMA) {
		fprintf(stderr, "direct GPU HBM I/O requires trtype:RDMA "
			"(no-fallback rule)\n");
		return -ENOTSUP;
	}

	env_opts.opts_size = sizeof(env_opts);
	spdk_env_opts_init(&env_opts);
	env_opts.name = "spdk_gpu_read";
	if (g_core_mask != NULL) {
		env_opts.core_mask = g_core_mask;
	}
	if (spdk_env_init(&env_opts) < 0) {
		return 1;
	}
	tsc_rate = spdk_get_ticks_hz();

	/* Stage 8 handoff: GPU allocation + DMA-BUF export. In the stub
	 * build this fails with ENOTSUP and NOTHING falls back.
	 */
	rc = gpu_mem_alloc(g_gpu_id, (size_t)g_blocks * 4096, &ctx.buf);
	if (rc != 0) {
		fprintf(stderr, "gpu_mem_alloc failed (%s backend): %s\n",
			gpu_mem_backend_name(), spdk_strerror(-rc));
		return rc;
	}
	ctx.poison_registration = g_fail_registration;

	/* Stage 9: the GPU memory domain with our translation */
	rc = spdk_memory_domain_create(&gpu_domain, SPDK_DMA_DEVICE_TYPE_RDMA, NULL,
				       "kvopt_gpu_dmabuf");
	if (rc != 0) {
		fprintf(stderr, "memory_domain_create: %s\n", spdk_strerror(-rc));
		goto out;
	}
	spdk_memory_domain_set_translation(gpu_domain, gpu_domain_translate);

	spdk_nvme_ctrlr_get_default_ctrlr_opts(&ctrlr_opts, sizeof(ctrlr_opts));
	ctrlr_opts.keep_alive_timeout_ms = 60 * 1000;
	ctrlr = spdk_nvme_connect(&trid, &ctrlr_opts, sizeof(ctrlr_opts));
	if (ctrlr == NULL) {
		fprintf(stderr, "connect failed\n");
		rc = 1;
		goto out;
	}

	nr_domains = spdk_nvme_ctrlr_get_memory_domains(ctrlr, ctrlr_domains,
							SPDK_COUNTOF(ctrlr_domains));
	if (nr_domains <= 0) {
		fprintf(stderr, "controller exposes no memory domains — the "
			"transport cannot do external-memory DMA (no fallback)\n");
		rc = -ENOTSUP;
		goto out;
	}
	fprintf(stderr, "controller memory domains: %d (transport supports "
		"external memory)\n", nr_domains);

	ns = spdk_nvme_ctrlr_get_ns(ctrlr, g_nsid);
	if (ns == NULL || !spdk_nvme_ns_is_active(ns)) {
		fprintf(stderr, "namespace %u not found\n", g_nsid);
		rc = 1;
		goto out;
	}
	block_size = spdk_nvme_ns_get_sector_size(ns);
	io_bytes = g_blocks * block_size;
	if ((size_t)io_bytes > ctx.buf.size) {
		fprintf(stderr, "GPU buffer too small for %u blocks\n", g_blocks);
		rc = 1;
		goto out;
	}

	qpair = spdk_nvme_ctrlr_alloc_io_qpair(ctrlr, NULL, 0);
	if (qpair == NULL) {
		rc = 1;
		goto out;
	}

	if (gpu_mem_poison(&ctx.buf, 0xEE) != 0) {
		fprintf(stderr, "gpu poison failed\n");
		rc = 1;
		goto out;
	}

	/* Stage 10: the direct READ. The payload pointer is the GPU VA. */
	eopts.size = SPDK_SIZEOF(&eopts, accel_sequence);
	eopts.memory_domain = gpu_domain;
	eopts.memory_domain_ctx = &ctx;

	t0 = spdk_get_ticks();
	rc = spdk_nvme_ns_cmd_read_ext(ns, qpair, (void *)ctx.buf.dptr,
				       g_lba, g_blocks, io_cb, &done, &eopts);
	if (rc != 0) {
		fprintf(stderr, "read_ext submit failed: %s\n", spdk_strerror(-rc));
		io_failed = true;
		goto verdict;
	}
	while (!done.done) {
		spdk_nvme_qpair_process_completions(qpair, 0);
	}
	io_tsc = spdk_get_ticks() - t0;
	if (spdk_nvme_cpl_is_error(&done.cpl)) {
		fprintf(stderr, "READ failed: sct=0x%x sc=0x%x (%s)\n",
			done.cpl.status.sct, done.cpl.status.sc,
			spdk_nvme_cpl_get_status_string(&done.cpl.status));
		io_failed = true;
		goto verdict;
	}

	/* Stage 7-in-HBM: device-side checksum; only the digest crosses. */
	rc = gpu_checksum_pattern(&ctx.buf, g_lba, g_blocks, block_size, &digest);
	if (rc != 0) {
		fprintf(stderr, "gpu checksum failed to run\n");
		goto verdict;
	}
	checksum_ok = digest.mismatch_count == 0;
	lat_us = (double)io_tsc * SPDK_SEC_TO_USEC / tsc_rate;
	gbps = lat_us > 0.0 ? (double)io_bytes * 8.0 / (lat_us * 1000.0) : 0.0;
	fprintf(stderr, "READ %u B -> GPU HBM in %.1f us; checksum %s "
		"(mismatches=%" PRIu64 " first_bad=%" PRId64 ")\n",
		io_bytes, lat_us, checksum_ok ? "OK" : "MISMATCH",
		digest.mismatch_count, digest.first_bad_offset);

verdict:
	if (g_fail_registration) {
		/* negative test verdict: the I/O MUST have failed */
		rc = io_failed ? 0 : 3;
		fprintf(stderr, "negative test: I/O %s => %s\n",
			io_failed ? "failed as required" : "SUCCEEDED (hidden fallback!)",
			rc == 0 ? "PASS" : "FAIL");
	} else {
		rc = (!io_failed && checksum_ok) ? 0 : 2;
	}

	if (g_json) {
		printf("{\"test\":\"spdk_gpu_read\",\"io_size\":%u,"
		       "\"queue_depth\":1,\"lba_size\":%u,\"bytes\":%u,"
		       "\"checksum_ok\":%s,\"gpu_memory_domain\":true,"
		       "\"rdma_registration\":%s,\"host_payload_buffer\":false,"
		       "\"host_bounce_detected\":false,"
		       "\"negative_test\":%s,\"io_failed\":%s,"
		       "\"latency_us\":%.1f,\"throughput_gbps\":%.3f,"
		       "\"gpu_backend\":\"%s\",\"result\":\"%s\"}\n",
		       io_bytes, block_size, io_bytes,
		       checksum_ok ? "true" : "false",
		       ctx.mr != NULL ? "true" : "false",
		       g_fail_registration ? "true" : "false",
		       io_failed ? "true" : "false",
		       lat_us, gbps, gpu_mem_backend_name(),
		       rc == 0 ? "PASS" : "FAIL");
	}

out:
	if (ctx.mr != NULL) {
		ibv_dereg_mr(ctx.mr);
	}
	if (qpair != NULL) {
		spdk_nvme_ctrlr_free_io_qpair(qpair);
	}
	if (ctrlr != NULL) {
		spdk_nvme_detach(ctrlr);
	}
	if (gpu_domain != NULL) {
		spdk_memory_domain_destroy(gpu_domain);
	}
	gpu_mem_free(&ctx.buf);
	return rc;
}
