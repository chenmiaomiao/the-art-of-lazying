# Google Play Physical-Device Delivery With Scoped Astrill

## Purpose

Use this runbook when Google Play Console and tester enrollment are valid, but
a physical Android device in a restricted network cannot download the exact
internal-test build. It keeps Ubuntu, Codex, SSH, the Mac, and unrelated LAN
devices on their normal route while one phone reaches explicitly named Play
endpoints.

This procedure qualifies delivery only when Google Play performs the install.
An upload-signed APK installed with ADB is useful application QA, but it cannot
prove Play deployment signing, Play installer attribution, or storefront
delivery.

## Preconditions

- Read the Play track through the provider API or authenticated Console and
  record the exact active version code.
- Confirm the phone's current Play account is actually invited and has accepted
  the internal-test program.
- Record the phone's exact current LAN IPv4 address and router-observed MAC in
  private runtime state. Never put either value in a public command example.
- Keep signed download URLs, account identifiers, browser profiles, and service
  account material out of logs and Git.
- Audit both the companion overlay and native Astrill defaults. A scoped overlay
  does not override an independently global native website policy.

## Create One Temporary Route

Start with only the control-plane hostnames observed in current phone logs:

```bash
astrill-lazy device-flow set \
  --owner <release-and-device-owner> \
  --source <phone-ipv4> \
  --mac <router-observed-phone-mac> \
  --domain <exact-play-hostname> \
  --protocol tcp \
  --protocol udp \
  --port 443 \
  --target vpn

astrill-lazy device-flow list --owner <release-and-device-owner>
```

Do not add wildcard domains, Google-wide networks, a subnet source, or the
workstation itself. Domain routing is enforced against resolved IPv4 addresses;
another hostname sharing one CDN IP is an unavoidable IP-layer limitation.

## Refresh The Play Request

If Play cached a failed or older request, preserve accounts and tester state by
clearing only the Play Store cache:

1. Force-stop Google Play Store.
2. Open its system App info page.
3. Select Storage, Clear data, then Clear cache.
4. Reopen the exact internal-test listing with the invited Play account.
5. Start the install once and inspect bounded, redacted logs.

Useful evidence includes:

- the scheduled version code;
- split count and total byte count;
- download lifecycle state without the signed URL;
- final package version and installer attribution; and
- the installed split signer fingerprint.

Never copy a `play-apps-download` URL into a report. Its query string is an
ephemeral signed capability and often binds delivery context such as egress.

## Diagnose The China-Local CDN Case

Some China-ROM Play clients request `xn--ngstr-lra8j.com` download edges. Keep
three failures distinct:

1. **Connection timeout:** the DNS-selected edge cannot be reached on that path.
2. **HTTP 400 from a reachable sibling edge:** transport works, but the signed
   URL is invalid for that edge or egress. This is not a successful workaround.
3. **Package install failure after complete download:** inspect PackageInstaller
   and signer evidence; this is a different layer.

Do not rewrite signed query parameters, report a sibling-edge TLS response as a
successful download, or manually install downloaded splits and call that a Play
install. A temporary destination translation may diagnose edge reachability,
but it qualifies nothing unless Google Play completes the original transaction.

## Verified 2026-08-10 Result

The EchoMind Internal track was Active and exposed exact version code `65` to
the invited account. Play scheduled five splits for version `65`. One small
resource completed, while candidate splits either timed out on DNS-selected
China-local edges or returned HTTP `400` through reachable sibling edges.
The original, Hong Kong, and China-optimized Astrill endpoint classes did not
produce a valid end-to-end transaction.

Therefore:

- Console publication to Internal testing is verified;
- tester enrollment is verified;
- a Play-signed physical-device installation is not verified;
- deployment-certificate and launch-smoke evidence remain open; and
- formal Production submission must continue to honor every independent
  metadata, legal, screenshot, device, and accountable-approval gate.

## Upload-Signed QA On MIUI

An exact upload-signed QA APK can test application behavior while Play delivery
is unavailable, but keep its evidence class separate. Validate application ID,
version code, source commit, artifact hash, custody receipt, and upload signer
before installation. The result still cannot prove Play deployment signing,
installer attribution, or storefront delivery.

MIUI adds two relevant Developer options: **Install via USB** and **USB
debugging (Security settings)**. Enabling the first invokes Xiaomi's own
verification flow. A later ADB install may show a separate countdown dialog in
which **Install** is disabled until the countdown reaches zero. Do not select
**Remember my choice** before confirming the enabled action; preserving a deny
can make later sessions fail immediately with `INSTALL_FAILED_USER_RESTRICTED`.

Treat that dialog as a physical security boundary. If injected input does not
complete it, keep the QA gate open. Do not spoof `com.android.vending` as the
installer, weaken persistent verification settings, or report the upload-signed
APK as Play-signed. Restore any bounded diagnostic setting before ending the
session.

## Mandatory Cleanup

Stop the failed Play retry, then remove the owner even when installation fails:

```bash
astrill-lazy device-flow delete --owner <release-and-device-owner>
astrill-lazy device-flow list --owner <release-and-device-owner>
```

Also remove any bounded diagnostic-only packet-mark or destination-translation
chain, restore the selected Astrill endpoint, and verify:

- the owner readback is empty;
- no diagnostic chain remains in `mangle` or `nat`;
- companion health and precedence are ready;
- native website and device defaults are Direct for task-only operation; and
- ordinary host and phone traffic use the expected non-Astrill egress.

Keep a private mode-`0600` backup before changing native site policy. The final
verified cleanup restored the original endpoint, retained a healthy connected
tunnel for future scoped tasks, set unmatched traffic Direct, and removed every
EchoMind phone overlay and diagnostic chain.

## Mac Release Safety

This Android delivery investigation does not require iOS Simulator. On an
Intel Hackintosh affected by `SimMetalHost` GPU hangs, keep Simulator shut down
and use physical iPhone/iPad hardware plus command-line artifact/provider tools.
