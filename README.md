# prerequisites
- VM
  - [Azure](https://azure.microsoft.com/)
  - [HOSTKVM](https://hostkvm.com/)
- Domain
  - [GoDaddy](https://www.godaddy.com/)
- Client tool
  - [Maple](https://github.com/YtFlow/Maple)
  - [Mellow](https://github.com/mellow-io/mellow)(No longer supported)

# install (interactive)
```bash
./install_trojan.sh
```

## non-interactive usage
```bash
# install trojan
./install_trojan.sh --install -d your.domain.com -p 443

# specify custom install log file & enable debug trace
./install_trojan.sh --install -d your.domain.com -p 443 --log-file /tmp/trojan-install.log --debug

# uninstall trojan
./install_trojan.sh --remove -y

# install bbr-plus
./install_trojan.sh --bbr

# run renew immediately
./install_trojan.sh --renew-now

# install systemd timer (alternative to cron) for renew
./install_trojan.sh --install-renew
```

Run `./install_trojan.sh --help` to see full options.

## client configuration
Use your own trojan / compatible client and fill:
- remote_addr: your.domain.com
- remote_port: (the port you chose, e.g. 443)
- password: (script output password)
- TLS: enable verification; SNI = your.domain.com

Certificates are installed at `/usr/src/trojan-cert` (fullchain.cer & private.key) for server use; clients only need to trust public CAs.

## certificate auto renew
- acme.sh sets up a daily cron by default (script also ensures one at 03:15 each day)
- You can add a systemd timer with `--install-renew`
- Manual trigger: `./install_trojan.sh --renew-now`
- Check expiry:
  ```bash
  openssl x509 -in /usr/src/trojan-cert/fullchain.cer -noout -enddate
  ```

# debug
```bash
$ journalctl -u trojan
```
