"""Start the mem0 API on one socket that answers both IPv4 and IPv6.

Railway needs both: sibling services reach this container over IPv6 on the
private network, while the health checker and the public edge arrive over IPv4.
`uvicorn --host ::` cannot do this, because python's asyncio unconditionally
sets the v6-only flag on an IPv6 socket, and `--host 0.0.0.0` loses the private
network. So the socket is built here with that flag cleared and handed to
uvicorn already bound.
"""

import os
import socket

import uvicorn

PORT = int(os.environ.get("PORT", "8000"))


def dual_stack_socket(port: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", port))
    sock.listen(2048)
    sock.set_inheritable(True)
    return sock


def main() -> None:
    sock = dual_stack_socket(PORT)
    print(f"mem0 api listening on [::]:{PORT} (dual stack)", flush=True)
    # Railway terminates TLS at the edge, so the real client address only exists
    # in the forwarded headers. Without this the per-IP rate limit on the login
    # and registration endpoints would count every visitor as the same caller.
    config = uvicorn.Config(
        "main:app",
        proxy_headers=True,
        forwarded_allow_ips="*",
    )
    uvicorn.Server(config).run(sockets=[sock])


if __name__ == "__main__":
    main()
