/*
 * Direct write whose source buffer is a file-backed mmap page.
 * The folio belongs to the page cache (mapping != NULL, not anon), but
 * O_DIRECT pins it, so SAMON must skip it via the DMA-pinned check
 * (stats: skip_pinned) and must not record it.
 *
 * usage: test_pinned <src_file> <dst_file> [size_bytes]
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	size_t size = argc > 3 ? strtoul(argv[3], NULL, 0) : 1 << 20;
	int src, dst;
	char *buf;
	size_t i;

	if (argc < 3) {
		fprintf(stderr, "usage: %s src dst [size]\n", argv[0]);
		return 2;
	}
	src = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (src < 0 || ftruncate(src, size)) { perror("src"); return 1; }
	buf = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, src, 0);
	if (buf == MAP_FAILED) { perror("mmap"); return 1; }
	for (i = 0; i < size; i += 4096)	/* fault pages in */
		buf[i] = (char)i;

	dst = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC | O_DIRECT, 0644);
	if (dst < 0) { perror("dst(O_DIRECT)"); return 1; }
	if (write(dst, buf, size) != (ssize_t)size) { perror("write"); return 1; }
	fsync(dst);
	close(dst);
	munmap(buf, size);
	close(src);
	return 0;
}
