# SSH and git over SSH

SSH ignores `https_proxy`. GFW interference on GitHub is selective: at the same moment an HTTPS download
can succeed while the SSH handshake is reset, on port 22 and on 443. A reachable TCP port does not mean the
handshake passes, because the block sits at the protocol layer.

Route SSH through Clash's SOCKS port with `connect.exe`, which ships with Git for Windows. Port 7890 is a
mixed port, so SOCKS5 works there.

```bash
# 1. locate connect.exe
command -v connect || cygpath -w /mingw64/bin/connect.exe

# 2. smoke-test the tunnel: an SSH banner means it works
timeout 12 /mingw64/bin/connect.exe -S 127.0.0.1:7890 ssh.github.com 443
# success prints: SSH-2.0-...

# 3. one-off push, no permanent config change
GIT_SSH_COMMAND='ssh -o ProxyCommand="/mingw64/bin/connect.exe -S 127.0.0.1:7890 %h %p"' git push origin master
```

To make it permanent, add a github.com block to `~/.ssh/config`. ssh config is read by cmd, so it needs a
Windows absolute path. Take the real one from `cygpath -w /mingw64/bin/connect.exe`:

```ini
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    ProxyCommand <absolute path to connect.exe> -S 127.0.0.1:7890 %h %p
```

With Clash closed, this ProxyCommand makes SSH fail outright. That is an accepted trade-off: direct SSH is
intermittent anyway, and the proxy route is steadier.
