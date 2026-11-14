/* Official-library harness for FLUSH / EMIT_METADATA semantics (brotli 1.1.0).
 *
 *   harness flush Q W IN OUT_PREFIX OUT_FULL
 *     - PROCESS first half of IN, then FLUSH (fully drained), write the
 *       flush prefix (the bytes emitted by the flush) to OUT_PREFIX;
 *     - PROCESS the rest, FINISH, write the whole stream to OUT_FULL
 *       (OUT_FULL is self-contained: prefix bytes + remaining bytes).
 *   harness meta Q W IN META OUT
 *     - PROCESS all of IN, EMIT_METADATA META, FINISH -> OUT.
 *   harness metapad Q W IN OUT
 *     - PROCESS all of IN, EMIT_METADATA "" (empty), FINISH -> OUT.
 */
#include <brotli/encode.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int read_all(const char* path, unsigned char** buf, size_t* n) {
	FILE* f = fopen(path, "rb");
	if (!f) return 0;

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	*buf = (unsigned char*)malloc(sz > 0 ? (size_t)sz : 1);
	*n = fread(*buf, 1, (size_t)sz, f);

	fclose(f);
	return 1;
}

static int write_all(const char* path, const unsigned char* buf, size_t n) {
	FILE* f = fopen(path, "wb");
	if (!f) return 0;

	if (n && fwrite(buf, 1, n, f) != n) {
		fclose(f);
		return 0;
	}

	fclose(f);
	return 1;
}

#define CAP (16u << 20)

int main(int argc, char** argv) {
	if (argc < 5) {
		fprintf(stderr, "usage: harness flush|meta|metapad ...\n");
		return 2;
	}

	const char* mode = argv[1];
	int q = atoi(argv[2]);
	int w = atoi(argv[3]);
	unsigned char* in = NULL;
	size_t in_n = 0;
	if (!read_all(argv[4], &in, &in_n)) {
		perror("read");
		return 2;
	}

	unsigned char* out = (unsigned char*)malloc(CAP);
	size_t out_n = 0;

	BrotliEncoderState* s = BrotliEncoderCreateInstance(NULL, NULL, NULL);
	BrotliEncoderSetParameter(s, BROTLI_PARAM_QUALITY, (uint32_t)q);
	BrotliEncoderSetParameter(s, BROTLI_PARAM_LGWIN, (uint32_t)w);
	BrotliEncoderSetParameter(s, BROTLI_PARAM_SIZE_HINT, (uint32_t)in_n);

	if (strcmp(mode, "flush") == 0) {
		size_t half = in_n / 2;
		const unsigned char* next_in = in;
		size_t avail_in = half;
		unsigned char* next_out = out;
		size_t avail_out = CAP;
		while (avail_in > 0) {
			BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_PROCESS,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
		}
		size_t pre_flush = (size_t)(next_out - out);
		for (;;) {
			avail_in = 0;
			next_in = in;
			BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_FLUSH,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
			if (!BrotliEncoderHasMoreOutput(s)) break;
		}
		size_t flush_len = (size_t)(next_out - out);
		(void)pre_flush;
		if (!write_all(argv[5], out, flush_len)) {
			perror("write prefix");
			return 2;
		}
		next_in = in + half;
		avail_in = in_n - half;
		while (avail_in > 0 || !BrotliEncoderIsFinished(s)) {
			if (avail_in == 0) {
				BrotliEncoderCompressStream(
					s,
					BROTLI_OPERATION_FINISH,
					&avail_in,
					&next_in,
					&avail_out,
					&next_out,
					NULL
				);
			} else {
				BrotliEncoderCompressStream(
					s,
					BROTLI_OPERATION_PROCESS,
					&avail_in,
					&next_in,
					&avail_out,
					&next_out,
					NULL
				);
			}
			if (BrotliEncoderIsFinished(s)) break;
		}
		out_n = (size_t)(next_out - out);
		if (!write_all(argv[6], out, out_n)) {
			perror("write full");
			return 2;
		}
	} else if (strcmp(mode, "meta") == 0 || strcmp(mode, "metapad") == 0) {
		unsigned char* meta = NULL;
		size_t meta_n = 0;
		if (strcmp(mode, "meta") == 0 && !read_all(argv[5], &meta, &meta_n)) {
			perror("read meta");
			return 2;
		}
		const char* out_path = (strcmp(mode, "meta") == 0) ? argv[6] : argv[5];
		const unsigned char* next_in = in;
		size_t avail_in = in_n;
		unsigned char* next_out = out;
		size_t avail_out = CAP;
		while (avail_in > 0) {
			BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_PROCESS,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
		}
		next_in = meta ? meta : (const unsigned char*)"";
		avail_in = meta_n;
		for (;;) {
			BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_EMIT_METADATA,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
			if (avail_in == 0 && !BrotliEncoderHasMoreOutput(s)) break;
		}
		next_in = in;
		avail_in = 0;
		while (!BrotliEncoderIsFinished(s)) {
			BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_FINISH,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
		}
		out_n = (size_t)(next_out - out);
		if (!write_all(out_path, out, out_n)) {
			perror("write");
			return 2;
		}
	} else {
		fprintf(stderr, "unknown mode %s\n", mode);
		return 2;
	}
	BrotliEncoderDestroyInstance(s);
	free(out);
	return 0;
}
