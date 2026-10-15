# schannel errors: curl and git on Windows

Windows curl is built against Schannel only. `curl -V` lists `Schannel` and no OpenSSL, so curl cannot
switch TLS backends. git for Windows usually includes OpenSSL, so git can.

## Which error

**`CRYPT_E_REVOCATION_OFFLINE`**: Schannel could not reach the certificate revocation server. It is
usually transient. The Diplomat feed failed this way once, then returned 200 on five tries. Retry once.
Do not add `--ssl-no-revoke` to make it pass: that turns off a security check for the whole command.
Disable the check only when the user accepts that for this host.

**`failed to receive handshake, SSL/TLS connection failed`** or **`UNEXPECTED_EOF`**: the connection is
closed during the TLS handshake. This is often intermittent per host: thediplomat.com answered 200 five
times, then failed every time minutes later while wikipedia.org and github.com kept working. Retest before
concluding anything, then separate the route from the backend with a second TLS stack:

```bash
python -c "
import urllib.request
o = urllib.request.build_opener(urllib.request.ProxyHandler({'https': 'http://127.0.0.1:7890'}))
print(o.open('<url>', timeout=30).status)
"
```

Use `python`. On Git Bash, `python3` can be a Windows Store stub that exits without running.

- Both stacks fail: the route to that host is blocked at the node, or it is intermittent. Retest a few
  times first. If it fails consistently, change the Clash node or rule.
- Only schannel fails: the TLS backend is the problem. For git, switch the backend (below). For curl there
  is no switch on this machine, so make that request with Python.

## git over https

```bash
# one-off push or fetch, no permanent config change
git -c http.proxy=http://127.0.0.1:7890 -c http.sslBackend=openssl push origin master
```

Check `git version --build-options` for `openssl` first. A permanent change is
`git config --global http.proxy` plus `http.sslBackend openssl`; ask before editing the global config.
`http.proxy` applies only to git, while `https_proxy` also applies to curl and pip.
