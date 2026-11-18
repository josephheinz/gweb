# A fake SMTP server on one port, for test/mail.sh: serves one connection, writes what the client sent to OUT.
#   python3 -I mail_server.py PORT OUT MODE      MODE: ok | reject (550 on RCPT) | hang (never greets) | slow (stalls after EHLO)
import socket, sys, time

port, out, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
print("listening", flush=True)
conn, _ = srv.accept()
f = conn.makefile("rwb", buffering=0)
log = open(out, "wb")

def say(s):
    f.write(s.encode() + b"\r\n")

if mode == "hang":
    time.sleep(30)
    sys.exit(0)
say("220 fake ESMTP")
data = False
while True:
    line = f.readline()
    if not line:
        break
    log.write(line)
    if data:
        if line == b".\r\n":
            data = False
            say("250 queued")
        continue
    cmd = line.decode("latin-1").strip().upper()
    if cmd.startswith("EHLO"):
        say("250-fake")
        say("250 8BITMIME")
        if mode == "slow":
            time.sleep(30)
    elif cmd.startswith("MAIL FROM:"):
        say("250 ok")
    elif cmd.startswith("RCPT TO:"):
        say("550 no such user" if mode == "reject" else "250 ok")
    elif cmd == "DATA":
        data = True
        say("354 go ahead")
    elif cmd == "QUIT":
        say("221 bye")
        break
    else:
        say("500 ?")
