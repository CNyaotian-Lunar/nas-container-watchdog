#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 本工具由 DeepSeek（DSH agent）编写，由 CNyaotian 维护与发布。
"""看门狗告警邮件发送器（纯标准库，无需 pip 安装任何东西）

用法:
    watchdog-mail.py "<主题>" <正文文件路径|->
    （正文传 "-" 表示从 stdin 读）

凭据文件（默认取本脚本所在目录下的 watchdog-mail.env；也可用环境变量 WATCHDOG_MAIL_ENV
指定其他路径。建议权限 600）:

    SMTP_HOST=smtp.163.com
    SMTP_PORT=465
    SMTP_USER=你的邮箱@163.com
    SMTP_PASS=客户端授权码          # 不是登录密码！
    MAIL_FROM=你的邮箱@163.com      # 163 要求必须与 SMTP_USER 一致
    MAIL_TO=收件邮箱@example.com    # 多个用英文逗号分隔

退出码:
    0 发送成功 / 1 凭据问题 / 2 参数问题 / 3 发送失败
"""

import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from email.utils import formatdate

CONF_PATH = os.environ.get("WATCHDOG_MAIL_ENV") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "watchdog-mail.env")


def load_conf(path):
    cfg = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                cfg[key.strip().upper()] = value.strip().strip('"').strip("'")
    except OSError as exc:
        print("无法读取凭据文件 %s: %s" % (path, exc), file=sys.stderr)
        sys.exit(1)
    return cfg


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    subject, body_src = sys.argv[1], sys.argv[2]
    if body_src == "-":
        body = sys.stdin.read()
    else:
        with open(body_src, "r", encoding="utf-8") as fh:
            body = fh.read()

    cfg = load_conf(CONF_PATH)
    host = cfg.get("SMTP_HOST", "smtp.163.com")
    try:
        port = int(cfg.get("SMTP_PORT", "465"))
    except ValueError:
        print("SMTP_PORT 必须是数字，当前值: %r" % cfg.get("SMTP_PORT"), file=sys.stderr)
        return 2
    user = cfg.get("SMTP_USER")
    password = cfg.get("SMTP_PASS")
    sender = cfg.get("MAIL_FROM", user)
    recipients = [a.strip() for a in cfg.get("MAIL_TO", "").split(",") if a.strip()]

    missing = [k for k, v in (("SMTP_USER", user), ("SMTP_PASS", password)) if not v]
    if missing or not recipients:
        if not recipients:
            missing.append("MAIL_TO")
        print("凭据不完整，缺少: %s" % ", ".join(missing), file=sys.stderr)
        return 1

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg["Date"] = formatdate(localtime=True)
    msg.set_content(body)

    ctx = ssl.create_default_context()
    try:
        if port == 465:
            with smtplib.SMTP_SSL(host, port, timeout=25, context=ctx) as smtp:
                smtp.login(user, password)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=25) as smtp:
                smtp.ehlo()
                smtp.starttls(context=ctx)
                smtp.login(user, password)
                smtp.send_message(msg)
    except Exception as exc:  # noqa: BLE001 —— 需要把各种 SMTP 异常原样报给看门狗日志
        print("发送失败: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 3

    print("已发送 -> %s" % ", ".join(recipients))
    return 0


if __name__ == "__main__":
    sys.exit(main())
