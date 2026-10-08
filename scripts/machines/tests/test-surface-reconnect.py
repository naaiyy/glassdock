#!/usr/bin/env python3
"""Compile and test the exact surface reader introduced by the CocoaSpice patch."""
import pathlib
import re
import subprocess
import tempfile
import unittest

class SurfaceReconnectTests(unittest.TestCase):
    def test_replayed_surface_and_legacy_pipe(self):
        patch = pathlib.Path(__file__).resolve().parents[1] / 'patches/cocoaspice-initial-frame.patch'
        added = '\n'.join(line[1:] for line in patch.read_text().splitlines() if line.startswith('+') and not line.startswith('+++'))
        reader = re.search(r'static ssize_t cs_read_surface_id\(.*?\n}', added, re.S).group()
        harness = '''
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <assert.h>
#include <poll.h>
typedef uint32_t IOSurfaceID;
READER
int main(void) {
    int fds[2]; IOSurfaceID expected=123456, actual=0;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds)==0);
    assert(fcntl(fds[0], F_SETFL, O_NONBLOCK)==0);
    assert(write(fds[1], &expected, sizeof(expected))==sizeof(expected));
    // First viewer reads the surface; a later viewer gets the server's dup fd.
    assert(cs_read_surface_id(fds[0], &actual)==sizeof(actual));
    assert(actual==expected);
    int later=dup(fds[0]); assert(later>=0); actual=0;
    assert(cs_read_surface_id(later, &actual)==sizeof(actual));
    assert(actual==expected);
    // Destroying the surface invalidates outstanding descriptors.
    close(fds[1]); struct pollfd p={later,POLLIN,0};
    assert(poll(&p,1,0)==1); assert(p.revents&POLLHUP);
    close(later); close(fds[0]);
    // Compatibility with the prebuilt bootstrap's one-shot pipe transport.
    assert(pipe(fds)==0); assert(write(fds[1], &expected, sizeof(expected))==sizeof(expected));
    actual=0; assert(cs_read_surface_id(fds[0], &actual)==sizeof(actual));
    assert(actual==expected); close(fds[0]); close(fds[1]);
    return 0;
}
'''.replace('READER',reader)
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary); source=root/'surface.c'; binary=root/'surface'
            source.write_text(harness)
            subprocess.run(['cc','-Wall','-Werror',str(source),'-o',str(binary)],check=True,capture_output=True)
            subprocess.run([str(binary)],check=True,timeout=5,capture_output=True)

if __name__ == '__main__': unittest.main()
