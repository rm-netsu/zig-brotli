/* Official-library cross-validation harness (brotli 1.1.0 API).
 *
 *   harness d [--large] IN OUT        decode IN into OUT
 *   harness c Q W [--large] IN OUT    encode IN into OUT (quality Q, lgwin W)
 *
 * --large sets BROTLI_{DECODER,ENCODER}_PARAM_LARGE_WINDOW, which the
 * official CLI does not expose; the library API does.
 */
#include <brotli/decode.h>
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

int main(int argc, char** argv) {
	int i;
	int large = 0;
	int mode_idx = -1;
	/* Flags may appear anywhere before IN OUT. */
	for (i = 1; i < argc - 2; ++i) {
		if (strcmp(argv[i], "--large") == 0) {
			large = 1;
		} else if (mode_idx < 0) {
			mode_idx = i;
		}
	}
	if (mode_idx < 0 || argc < 3) {
		fprintf(stderr, "usage: harness d|c ... IN OUT\n");
		return 2;
	}
	const char* mode = argv[mode_idx];
	const char* in_path = argv[argc - 2];
	const char* out_path = argv[argc - 1];

	unsigned char* in = NULL;
	size_t in_n = 0;
	if (!read_all(in_path, &in, &in_n)) {
		perror("read");
		return 2;
	}

	unsigned char* out = NULL;
	size_t out_n = 0;

	if (strcmp(mode, "d") == 0) {
		size_t cap = in_n * 4 + 65536;
		out = (unsigned char*)malloc(cap);
		BrotliDecoderState* s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
		if (large) {
			BrotliDecoderSetParameter(s, BROTLI_DECODER_PARAM_LARGE_WINDOW, 1);
		}
		const unsigned char* next_in = in;
		unsigned char* next_out = out;
		size_t avail_in = in_n, avail_out = cap;
		BrotliDecoderResult r = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
		while (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
			r = BrotliDecoderDecompressStream(
				s,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			);
			if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
				size_t used = (size_t)(next_out - out);
				cap *= 2;
				out = (unsigned char*)realloc(out, cap);
				next_out = out + used;
				avail_out = cap - used;
			}
		}
		if (r != BROTLI_DECODER_RESULT_SUCCESS) {
			fprintf(stderr, "official decode failed: %d\n", (int)r);
			return 1;
		}
		out_n = (size_t)(next_out - out);
		BrotliDecoderDestroyInstance(s);
	} else if (strcmp(mode, "c") == 0) {
		if (mode_idx + 2 >= argc - 2) {
			fprintf(stderr, "harness c needs Q W\n");
			return 2;
		}
		int q = atoi(argv[mode_idx + 1]);
		int w = atoi(argv[mode_idx + 2]);
		size_t cap = BrotliEncoderMaxCompressedSize(in_n);
		out = (unsigned char*)malloc(cap);
		BrotliEncoderState* s = BrotliEncoderCreateInstance(NULL, NULL, NULL);
		BrotliEncoderSetParameter(s, BROTLI_PARAM_QUALITY, (uint32_t)q);
		BrotliEncoderSetParameter(s, BROTLI_PARAM_LGWIN, (uint32_t)w);
		BrotliEncoderSetParameter(s, BROTLI_PARAM_SIZE_HINT, (uint32_t)in_n);
		if (large) {
			BrotliEncoderSetParameter(s, BROTLI_PARAM_LARGE_WINDOW, 1);
		}
		const unsigned char* next_in = in;
		unsigned char* next_out = out;
		size_t avail_in = in_n, avail_out = cap;
		if (
			!BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_PROCESS,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			) || !BrotliEncoderCompressStream(
				s,
				BROTLI_OPERATION_FINISH,
				&avail_in,
				&next_in,
				&avail_out,
				&next_out,
				NULL
			) || !BrotliEncoderIsFinished(s)
		) {
			fprintf(stderr, "official encode failed\n");
			return 1;
		}
		out_n = (size_t)(next_out - out);
		BrotliEncoderDestroyInstance(s);
	} else {
		fprintf(stderr, "unknown mode %s\n", mode);
		return 2;
	}

	if (!write_all(out_path, out, out_n)) {
		perror("write");
		return 2;
	}
	return 0;
}
