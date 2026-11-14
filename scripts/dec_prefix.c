/* Decode exactly the bytes of a file (prefix) with the official decoder,
 * reporting produced output length and the final result code. */
#include <brotli/decode.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: dec_prefix PREFIX\n");
		return 2;
	}

	FILE* f = fopen(argv[1], "rb");
	if (!f) {
		perror("open");
		return 2;
	}

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char* in = (unsigned char*)malloc(sz ? (size_t)sz : 1);
	if (fread(in, 1, (size_t)sz, f) != (size_t)sz) {
		perror("read");
		return 2;
	}
	fclose(f);

	BrotliDecoderState* s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
	BrotliDecoderSetParameter(s, BROTLI_DECODER_PARAM_LARGE_WINDOW, 1u);
	size_t cap = 1 << 20;
	unsigned char* out = (unsigned char*)malloc(cap);
	const unsigned char* next_in = in;
	size_t avail_in = (size_t)sz;
	unsigned char* next_out = out;
	size_t avail_out = cap;
	size_t total_out = 0;
	BrotliDecoderResult r = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
	while (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
		r = BrotliDecoderDecompressStream(
			s,
			&avail_in,
			&next_in,
			&avail_out,
			&next_out,
			&total_out
		);
		if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
			size_t used = (size_t)(next_out - out);
			cap *= 2;
			out = (unsigned char*)realloc(out, cap);
			next_out = out + used;
			avail_out = cap - used;
		}
	}
	const char* rn = r == BROTLI_DECODER_RESULT_ERROR
		? "ERROR"
		: r == BROTLI_DECODER_RESULT_SUCCESS
		? "SUCCESS"
		: r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT
		? "NEEDS_MORE_INPUT"
		: "NEEDS_MORE_OUTPUT";
	fprintf(
		stderr,
		"result=%s avail_in_left=%zu total_out=%zu\n",
		rn,
		avail_in,
		total_out
	);
	fwrite(out, 1, total_out, stdout);
	BrotliDecoderDestroyInstance(s);
	return 0;
}
