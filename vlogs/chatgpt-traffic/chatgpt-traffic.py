import dns.resolver

custom_ips = [
    "167.172.69.107",
    '104.236.71.191',
    '161.35.185.30',
    '164.90.138.10',
    '10.0.149.168',
    '158.101.107.181',
    '150.136.74.51',
    '45.55.70.87',
    '167.71.181.51',
    '10.0.145.245'
]

cidr = [
    "23.102.140.112/28",
    "13.66.11.96/28",
    "23.98.142.176/28",
    "40.84.180.224/28"
]

# List of domains to look up
domains = [
    'amp-api-edge.apps.apple.com',
    'api.revenuecat.com',
    'api.statsig.com',
    'ios.chat.openai.com',
    'o33249.ingest.sentry.io',
    'browser-intake-dataloghq.com',
    'chatgpt.livekit.cloud',
    'files.oaiusercontent.com',
    'ingest.sentry.io',
    'api.revenuecat.com',
    'inappcheck.itunes.apple.com',
    'chatgpt.livekit.cloud',
    'api.statsig.com',
    'ocsp.digicert.com',
    'amp-api-edge.apps.apple.com',
    'zerossl.ocsp.sectigo.com',
    'browser-intake-datadoghq.com',
    'ios.chat.openai.com',
    'ocsp.usertrust.com',
    'chat.openai.com'
    'android.chat.openai.com',
    'auth0.openai.com',
    'platform.openai.com',
    'chat.openai.com',
    'tcr9i.chat.openai.com',
    'openai.com',
    'chatgpt.com',
    'cdn.oaistatic.com',
    'oaistatic.com',
    'widget.intercom.io',
    'intercom.io',
    'js.intercomcdn.com',
    'intercomcdn.com',
    'featuregates.org',
    'api-iam.intercom.io',
    'events.statsigapi.net',
    'statsigapi.net',
    # 'googleusercontent.com',
    'lh3.googleusercontent.com',
    'www.cloudflare.com',
    'cloudflare.com',
]

# Function to get all IPs of a domain
def get_ips(domain):
    try:
        # Get 'A' records for IPv4 addresses
        answers = dns.resolver.resolve(domain, 'A')
        return [answer.to_text() for answer in answers]
    except dns.resolver.NoAnswer:
        return ["No A record found"]
    except dns.resolver.NXDOMAIN:
        return ["No such domain"]
    except Exception as e:
        return [f"Error obtaining IPs for domain {domain}: {e}"]

results = []

# Loop through domains and get their IPs
for domain in domains:
    ips = get_ips(domain)
    # print(f"The IP addresses of {domain} are: {ips}")
    # print(domain)
    results.append(domain)
    # print("\n".join(ips))

# Loop through domains and get their IPs
for domain in domains:
    ips = get_ips(domain)
    # print(f"The IP addresses of {domain} are: {ips}")
    # print(domain)
    # print("\n".join([ip+"/24" for ip in ips]))
    [results.append(ip) for ip in ips]

for ip in custom_ips:
    # print(ip + "/24")
    results.append (ip)

for ip in cidr:
    # print(ip)
    results.append(ip)

def unique(seq):
    seen = set()
    seen_add = seen.add
    return [x for x in seq if not (x in seen or seen_add(x) or x.startswith("Not"))]


for ip in unique(results):
    print(ip)
