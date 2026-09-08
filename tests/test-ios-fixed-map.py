#!/usr/bin/env python3
"""Exercise the actual patched Wine function with a mocked Darwin VM API.

Usage: python3 tests/test-ios-fixed-map.py /path/to/patched/wine
This verifies control flow, not whether a physical iPhone permits low VA maps.
"""
import pathlib
import subprocess
import sys
import tempfile

source = (pathlib.Path(sys.argv[1]) / "dlls/ntdll/unix/virtual.c").read_text()
start = source.index("#if defined(__APPLE__) && defined(__MACH__) && defined(WINE_IOS)\nstatic unsigned int wios_first_teb_fixed_map_captured;")
end = source.index("\nstatic void reserve_area(", start)
function = source[start:end]
prefix = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#undef MAP_FIXED_NOREPLACE
#undef MAP_TRYFIXED
#define __APPLE__ 1
#define __MACH__ 1
#define WINE_IOS 1
#define C_ASSERT(x) _Static_assert(x, #x)
#define VM_FLAGS_FIXED 0
#define VM_PROT_ALL 7
#define VM_INHERIT_COPY 1
#define MEMORY_OBJECT_NULL 0
#define KERN_SUCCESS 0
#define KERN_NO_SPACE 3
#define KERN_PROTECTION_FAILURE 2
typedef uintptr_t UINT_PTR;
typedef size_t SIZE_T;
typedef uintptr_t vm_address_t;
typedef size_t vm_size_t;
typedef int kern_return_t;
static void *user_shared_data = (void *)(uintptr_t)0x7ffe0000;
static int map_result, remap_fails, maps, remaps, releases;
static int mach_task_self(void) { return 1; }
static int vm_map(int task, vm_address_t *address, size_t size, int mask,
                  int flags, int object, int offset, int copy, int prot,
                  int maxprot, int inherit)
{
    assert(task == 1 && *address == (uintptr_t)user_shared_data);
    assert(size == 16384 && mask == 0 && flags == VM_FLAGS_FIXED);
    assert(!object && !offset && !copy && prot == PROT_READ);
    assert(maxprot == VM_PROT_ALL && inherit == VM_INHERIT_COPY);
    ++maps;
    return map_result;
}
static void *anon_mmap_fixed(void *start, size_t size, int prot, int flags)
{
    assert(map_result == KERN_SUCCESS); /* never overwrite on reservation failure */
    assert(start == user_shared_data && size == 16384 && prot == PROT_READ && !flags);
    ++remaps;
    if (remap_fails) { errno = ENOMEM; return MAP_FAILED; }
    return start;
}
static int vm_deallocate(int task, vm_address_t addr, size_t size)
{
    assert(task == 1 && addr == (uintptr_t)user_shared_data && size == 16384);
    ++releases;
    errno = EINVAL; /* cleanup must not clobber the original mmap failure */
    return 0;
}
static size_t unmap_area_above_user_limit(void *ptr, size_t size)
{
    (void)ptr; (void)size;
    abort(); /* the fixed Darwin path must never take hint-mismatch cleanup */
}
'''
suffix = r'''
static void check(int kr, int fail_remap, int expected_errno)
{
    maps = remaps = releases = 0;
    map_result = kr; remap_fails = fail_remap; errno = 0;
    void *result = anon_mmap_tryfixed(user_shared_data, 16384, PROT_READ, 0);
    assert(maps == 1);
    assert(remaps == (kr == KERN_SUCCESS));
    assert(releases == (kr == KERN_SUCCESS && fail_remap));
    assert(result == (expected_errno ? MAP_FAILED : user_shared_data));
    if (expected_errno) assert(errno == expected_errno);
    assert(wios_first_teb_fixed_map_mach_ret == kr);
    assert(wios_first_teb_fixed_map_final_errno == expected_errno);
    assert(strstr(wios_ntdll_get_first_teb_fixed_map_probe(), "primitive=VM_MAP_FIXED_IOS"));
}
int main(void)
{
    setenv("WIOS_FIRST_TEB_PROBE", "shared_user_data", 1);
    check(KERN_SUCCESS, 0, 0);
    check(KERN_NO_SPACE, 0, EEXIST);
    check(KERN_PROTECTION_FAILURE, 0, EACCES);
    check(6, 0, ENOMEM);
    check(KERN_SUCCESS, 1, ENOMEM);
    unsetenv("WIOS_FIRST_TEB_PROBE");
    wios_first_teb_fixed_map_captured = 0;
    map_result = 0; remap_fails = 0;
    assert(anon_mmap_tryfixed(user_shared_data, 16384, PROT_READ, 0) == user_shared_data);
    assert(!wios_first_teb_fixed_map_captured);
    puts("PASS: 6 native fixed-map control-flow cases (mock VM)");
}
'''
with tempfile.TemporaryDirectory(prefix="wios-map-test-") as temp:
    test = pathlib.Path(temp) / "test.c"
    test.write_text(prefix + function + suffix)
    binary = pathlib.Path(temp) / "test"
    subprocess.run(["cc", "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror",
                    str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
