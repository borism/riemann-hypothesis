/* Measure how well a running process's anonymous memory would compress in zram
 * (per 4 KiB page, as zram does) with lz4 and zstd. Read-only: the target is
 * stopped with SIGSTOP while its pages are read through /proc/PID/mem, then
 * continued. Zero pages are counted separately (zram stores them for free).
 *
 *   cc -O2 -o heap-compressibility scripts/heap-compressibility.c -llz4 -lzstd
 *   ./heap-compressibility PID [ZSTD_LEVEL]
 *
 * Used for the zram/swap measurements reported on issue #1.
 */
#include <lz4.h>
#include <zstd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s PID [ZSTD_LEVEL]\n", argv[0]); return 2; }
  int pid = atoi(argv[1]), lvl = argc > 2 ? atoi(argv[2]) : 1;
  char path[64]; snprintf(path, sizeof path, "/proc/%d/maps", pid);
  kill(pid, SIGSTOP);
  FILE *maps = fopen(path, "r");
  snprintf(path, sizeof path, "/proc/%d/mem", pid);
  int mem = open(path, O_RDONLY);
  if (!maps || mem < 0) { perror("open"); kill(pid, SIGCONT); return 1; }
  static char page[4096], out[8192];
  ZSTD_CCtx *z = ZSTD_createCCtx();
  unsigned long long pages = 0, zero = 0, lz = 0, zs = 0;
  char line[512];
  while (fgets(line, sizeof line, maps)) {
    unsigned long a, b; char perms[8]; unsigned long off; char dev[16]; unsigned long ino; char name[256] = "";
    int n = sscanf(line, "%lx-%lx %7s %lx %15s %lu %255s", &a, &b, perms, &off, dev, &ino, name);
    if (n < 6 || perms[0] != 'r' || perms[1] != 'w') continue;
    if (ino != 0 || (name[0] && strcmp(name, "[heap]") != 0 && strncmp(name, "[anon", 5) != 0)) continue;
    for (unsigned long p = a; p < b; p += 4096) {
      if (pread(mem, page, 4096, (off_t)p) != 4096) continue;
      pages++;
      int allz = 1; for (int i = 0; i < 4096; i += 8) if (*(unsigned long long *)(page + i)) { allz = 0; break; }
      if (allz) { zero++; continue; }
      int l = LZ4_compress_default(page, out, 4096, sizeof out); lz += (l > 0 && l < 4096) ? l : 4096;
      size_t s = ZSTD_compressCCtx(z, out, sizeof out, page, 4096, lvl); zs += (!ZSTD_isError(s) && s < 4096) ? s : 4096;
    }
  }
  kill(pid, SIGCONT);
  unsigned long long nz = pages - zero;
  printf("pid %d: %llu anon pages read (%.2f GiB), %llu zero; non-zero pages: lz4 ratio %.2f, zstd-%d ratio %.2f\n",
         pid, pages, pages * 4096.0 / (1 << 30), zero, nz ? nz * 4096.0 / lz : 0, lvl, nz ? nz * 4096.0 / zs : 0);
  return 0;
}
