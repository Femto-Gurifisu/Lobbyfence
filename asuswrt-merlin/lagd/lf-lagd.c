/*
 * lf-lagd - LobbyFence's lag simulator for routers without netem
 *
 * Holds the packets the firewall sends to one NFQUEUE queue for a while,
 * then lets them go (or drops a share of them):
 *
 *   lf-lagd -q <queue> [-d <delay ms>] [-j <jitter ms>] [-l <loss %>]
 *
 *   delay   every packet waits this long (0-5000 ms)
 *   jitter  plus/minus up to this much, at random (0-2000 ms)
 *   loss    this share of the packets is dropped (0-100, decimals allowed)
 *
 * The firewall rule should use "--queue-bypass": if this program is not
 * running, packets pass without lag instead of being dropped. On SIGTERM /
 * SIGINT every packet still waiting is let through before exiting.
 *
 * Talks to the kernel directly over netlink (no libnetfilter_queue needed),
 * uses integer maths only, and builds as a static binary for old ARM
 * routers. Linux 2.6.36 and newer.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <linux/netlink.h>

/* from linux/netfilter/nfnetlink.h and nfnetlink_queue.h (kept here so the
 * program builds with any toolchain's kernel headers) */
#define NFNL_SUBSYS_QUEUE	3
#define NFQNL_MSG_PACKET	0
#define NFQNL_MSG_VERDICT	1
#define NFQNL_MSG_CONFIG	2
#define NFQA_PACKET_HDR		1
#define NFQA_VERDICT_HDR	2
#define NFQA_CFG_CMD		1
#define NFQA_CFG_PARAMS		2
#define NFQA_CFG_QUEUE_MAXLEN	3
#define NFQA_CFG_MASK		4
#define NFQA_CFG_FLAGS		5
#define NFQNL_CFG_CMD_BIND	1
#define NFQNL_CFG_CMD_PF_BIND	3
#define NFQNL_CFG_CMD_PF_UNBIND	4
#define NFQNL_COPY_META		1
#define NFQA_CFG_F_FAIL_OPEN	(1 << 0)
#define NF_DROP			0
#define NF_ACCEPT		1

struct nfgenmsg { uint8_t nfgen_family; uint8_t version; uint16_t res_id; };
struct nfqnl_msg_config_cmd { uint8_t command; uint8_t _pad; uint16_t pf; };
struct nfqnl_msg_config_params { uint32_t copy_range; uint8_t copy_mode; } __attribute__((packed));
struct nfqnl_msg_packet_hdr { uint32_t packet_id; uint16_t hw_protocol; uint8_t hook; } __attribute__((packed));
struct nfqnl_msg_verdict_hdr { uint32_t verdict; uint32_t id; };

#define MAXPENDING 8192

struct pending { uint64_t at; uint32_t id; uint8_t verdict; };

static struct pending heap[MAXPENDING];
static int nheap;
static int nl = -1;
static uint16_t queue;
static uint32_t seq;
static volatile sig_atomic_t stop;
static uint64_t rnd = 88172645463325252ULL;

static uint64_t now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static uint32_t random32(void)
{
	rnd ^= rnd << 13; rnd ^= rnd >> 7; rnd ^= rnd << 17;
	return (uint32_t)(rnd >> 16);
}

/* ------------------------------------------------------------ min-heap */

static void heap_push(uint64_t at, uint32_t id, uint8_t verdict)
{
	int i = nheap++, p;
	while (i > 0) {
		p = (i - 1) / 2;
		if (heap[p].at <= at) break;
		heap[i] = heap[p];
		i = p;
	}
	heap[i].at = at; heap[i].id = id; heap[i].verdict = verdict;
}

static struct pending heap_pop(void)
{
	struct pending top = heap[0], last = heap[--nheap];
	int i = 0, c;
	while ((c = 2 * i + 1) < nheap) {
		if (c + 1 < nheap && heap[c + 1].at < heap[c].at) c++;
		if (last.at <= heap[c].at) break;
		heap[i] = heap[c];
		i = c;
	}
	heap[i] = last;
	return top;
}

/* ------------------------------------------------------------ netlink */

static void attr_put(char *buf, size_t *len, uint16_t type, const void *data, uint16_t dlen)
{
	struct nlattr *a = (struct nlattr *)(buf + *len);
	a->nla_type = type;
	a->nla_len = NLA_HDRLEN + dlen;
	memcpy((char *)a + NLA_HDRLEN, data, dlen);
	*len += NLA_ALIGN(a->nla_len);
}

static size_t msg_start(char *buf, uint16_t type, uint16_t flags, uint8_t family)
{
	struct nlmsghdr *h = (struct nlmsghdr *)buf;
	struct nfgenmsg *g = (struct nfgenmsg *)(buf + NLMSG_HDRLEN);
	memset(buf, 0, NLMSG_HDRLEN + NLMSG_ALIGN(sizeof(*g)));
	h->nlmsg_type = (NFNL_SUBSYS_QUEUE << 8) | type;
	h->nlmsg_flags = NLM_F_REQUEST | flags;
	h->nlmsg_seq = ++seq;
	g->nfgen_family = family;
	g->version = 0;
	g->res_id = htons(queue);
	return NLMSG_HDRLEN + NLMSG_ALIGN(sizeof(*g));
}

static int msg_send(char *buf, size_t len)
{
	struct sockaddr_nl to;
	((struct nlmsghdr *)buf)->nlmsg_len = (uint32_t)len;
	memset(&to, 0, sizeof(to));
	to.nl_family = AF_NETLINK;
	return sendto(nl, buf, len, 0, (struct sockaddr *)&to, sizeof(to)) < 0 ? -1 : 0;
}

static void verdict(uint32_t id, uint32_t v);

/* the packet id of a queued packet message, 0 = not one */
static int packet_id(struct nlmsghdr *h, uint32_t *id)
{
	struct nlattr *a;
	int alen;
	if (h->nlmsg_type != ((NFNL_SUBSYS_QUEUE << 8) | NFQNL_MSG_PACKET)) return 0;
	a = (struct nlattr *)((char *)NLMSG_DATA(h) + NLMSG_ALIGN(sizeof(struct nfgenmsg)));
	alen = (int)h->nlmsg_len - (int)NLMSG_LENGTH(NLMSG_ALIGN(sizeof(struct nfgenmsg)));
	while (alen >= (int)NLA_HDRLEN && a->nla_len >= NLA_HDRLEN && (int)a->nla_len <= alen) {
		if ((a->nla_type & NLA_TYPE_MASK) == NFQA_PACKET_HDR && a->nla_len >= NLA_HDRLEN + 4) {
			uint32_t pid;
			memcpy(&pid, (char *)a + NLA_HDRLEN, 4);
			*id = ntohl(pid);
			return 1;
		}
		alen -= NLA_ALIGN(a->nla_len);
		a = (struct nlattr *)((char *)a + NLA_ALIGN(a->nla_len));
	}
	return 0;
}

/* a config request, waiting for the kernel's answer: 0 or -errno */
static int config(uint8_t family, uint16_t attr, const void *data, uint16_t dlen)
{
	char buf[256], ans[4096];
	size_t len = msg_start(buf, NFQNL_MSG_CONFIG, NLM_F_ACK, family);
	ssize_t n;
	attr_put(buf, &len, attr, data, dlen);
	if (msg_send(buf, len) < 0) return -errno;
	for (;;) {
		struct nlmsghdr *h;
		n = recv(nl, ans, sizeof(ans), 0);
		if (n < 0) { if (errno == EINTR) continue; return -errno; }
		for (h = (struct nlmsghdr *)ans; NLMSG_OK(h, (unsigned)n); h = NLMSG_NEXT(h, n)) {
			uint32_t id;
			if (h->nlmsg_type == NLMSG_ERROR && h->nlmsg_seq == seq)
				return ((struct nlmsgerr *)NLMSG_DATA(h))->error;
			if (packet_id(h, &id))   /* traffic while still setting up: no lag yet */
				verdict(id, NF_ACCEPT);
		}
	}
}

static void verdict(uint32_t id, uint32_t v)
{
	/* (a verdict for a packet that is gone already just gets an error back) */
	char buf[64];
	struct nfqnl_msg_verdict_hdr vh;
	size_t len = msg_start(buf, NFQNL_MSG_VERDICT, 0, AF_UNSPEC);
	vh.verdict = htonl(v);
	vh.id = htonl(id);
	attr_put(buf, &len, NFQA_VERDICT_HDR, &vh, sizeof(vh));
	msg_send(buf, len);
}

/* ------------------------------------------------------------ main */

static void on_signal(int s) { (void)s; stop = 1; }

static int parse_ms(const char *s, long max, long *out)
{
	char *e;
	long v = strtol(s, &e, 10);
	if (*s == '\0' || *e != '\0' || v < 0 || v > max) return -1;
	*out = v;
	return 0;
}

/* "1.5" -> 15000 (loss in millionths... per 1 000 000) */
static int parse_loss(const char *s, uint32_t *out)
{
	uint32_t whole = 0, frac = 0, scale = 10000;
	const char *p = s;
	int digits = 0;
	if (*p == '\0') return -1;
	while (*p >= '0' && *p <= '9') { whole = whole * 10 + (uint32_t)(*p - '0'); if (whole > 100) return -1; p++; digits++; }
	if (*p == '.') {
		p++;
		while (*p >= '0' && *p <= '9') { if (scale > 1) { scale /= 10; frac += (uint32_t)(*p - '0') * scale; } p++; digits++; }
	}
	if (*p != '\0' || digits == 0) return -1;
	*out = whole * 10000 + frac;
	if (*out > 1000000) return -1;
	return 0;
}

static void usage(void)
{
	fprintf(stderr, "usage: lf-lagd -q <queue 0-65535> [-d <delay ms 0-5000>] [-j <jitter ms 0-2000>] [-l <loss %% 0-100>]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	long q = -1, delay = 0, jitter = 0;
	uint32_t loss = 0;
	int i, r, fam;
	struct sockaddr_nl me;
	struct nfqnl_msg_config_cmd cmd;
	struct nfqnl_msg_config_params params;
	uint32_t maxlen = htonl(MAXPENDING - 64), flags[2];
	static char buf[65536];
	struct sigaction sa;

	for (i = 1; i < argc; i++) {
		if (i + 1 >= argc) usage();
		if (!strcmp(argv[i], "-q")) { if (parse_ms(argv[++i], 65535, &q)) usage(); }
		else if (!strcmp(argv[i], "-d")) { if (parse_ms(argv[++i], 5000, &delay)) usage(); }
		else if (!strcmp(argv[i], "-j")) { if (parse_ms(argv[++i], 2000, &jitter)) usage(); }
		else if (!strcmp(argv[i], "-l")) { if (parse_loss(argv[++i], &loss)) usage(); }
		else usage();
	}
	if (q < 0) usage();
	queue = (uint16_t)q;
	rnd ^= ((uint64_t)getpid() << 32) ^ now_us();

	nl = socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER);
	if (nl < 0) { fprintf(stderr, "lf-lagd: netlink socket: %s\n", strerror(errno)); return 3; }
	memset(&me, 0, sizeof(me));
	me.nl_family = AF_NETLINK;
	if (bind(nl, (struct sockaddr *)&me, sizeof(me)) < 0) { fprintf(stderr, "lf-lagd: bind: %s\n", strerror(errno)); return 3; }
	r = 1 << 20;
	setsockopt(nl, SOL_SOCKET, SO_RCVBUF, &r, sizeof(r));

	/* old kernels need the protocol families bound once (newer ones ignore it) */
	for (fam = 0; fam < 2; fam++) {
		cmd.command = NFQNL_CFG_CMD_PF_UNBIND; cmd._pad = 0; cmd.pf = htons(fam ? AF_INET6 : AF_INET);
		config(AF_UNSPEC, NFQA_CFG_CMD, &cmd, sizeof(cmd));
		cmd.command = NFQNL_CFG_CMD_PF_BIND;
		config(AF_UNSPEC, NFQA_CFG_CMD, &cmd, sizeof(cmd));
	}
	cmd.command = NFQNL_CFG_CMD_BIND; cmd._pad = 0; cmd.pf = htons(AF_INET);
	r = config(AF_UNSPEC, NFQA_CFG_CMD, &cmd, sizeof(cmd));
	if (r) {
		fprintf(stderr, "lf-lagd: queue %u: %s\n", queue, r == -EPERM || r == -EBUSY ? "already in use" : strerror(-r));
		return 4;
	}
	params.copy_range = htonl(0);
	params.copy_mode = NFQNL_COPY_META;
	r = config(AF_UNSPEC, NFQA_CFG_PARAMS, &params, sizeof(params));
	if (r) { fprintf(stderr, "lf-lagd: queue %u settings: %s\n", queue, strerror(-r)); return 4; }
	config(AF_UNSPEC, NFQA_CFG_QUEUE_MAXLEN, &maxlen, sizeof(maxlen));
	/* queue full: let packets through rather than drop them (newer kernels) */
	flags[0] = htonl(NFQA_CFG_F_FAIL_OPEN); flags[1] = htonl(NFQA_CFG_F_FAIL_OPEN);
	{
		char b[256];
		size_t len = msg_start(b, NFQNL_MSG_CONFIG, NLM_F_ACK, AF_UNSPEC);
		attr_put(b, &len, NFQA_CFG_FLAGS, &flags[0], 4);
		attr_put(b, &len, NFQA_CFG_MASK, &flags[1], 4);
		msg_send(b, len);   /* an older kernel's error answer is skipped below */
	}

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	fprintf(stderr, "lf-lagd: queue %u: delay %ld ms, jitter %ld ms, loss %u.%04u %%\n",
		queue, delay, jitter, loss / 10000, loss % 10000);

	while (!stop) {
		uint64_t t = now_us();
		int timeout = -1;
		struct pollfd pfd;
		ssize_t n;

		while (nheap > 0 && heap[0].at <= t) {
			struct pending p = heap_pop();
			verdict(p.id, p.verdict);
		}
		if (nheap > 0) timeout = (int)((heap[0].at - t + 999) / 1000);
		pfd.fd = nl; pfd.events = POLLIN; pfd.revents = 0;
		r = poll(&pfd, 1, timeout);
		if (r < 0) { if (errno == EINTR) continue; break; }
		if (r == 0) continue;
		n = recv(nl, buf, sizeof(buf), MSG_DONTWAIT);
		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN) continue;
			if (errno == ENOBUFS) continue;   /* we fell behind: those packets pass by fail-open / timeout */
			break;
		}
		{
			struct nlmsghdr *h;
			for (h = (struct nlmsghdr *)buf; NLMSG_OK(h, (unsigned)n); h = NLMSG_NEXT(h, n)) {
				uint32_t id;
				if (!packet_id(h, &id)) continue;
				if (loss && random32() % 1000000 < loss) {
					verdict(id, NF_DROP);
					continue;
				}
				{
					long d = delay;
					if (jitter) d += (long)(random32() % (uint32_t)(2 * jitter + 1)) - jitter;
					if (d < 0) d = 0;
					if (d == 0 || nheap >= MAXPENDING) verdict(id, NF_ACCEPT);
					else heap_push(t + (uint64_t)d * 1000ULL, id, NF_ACCEPT);
				}
			}
		}
	}
	/* let everything still waiting go before the queue disappears */
	while (nheap > 0) {
		struct pending p = heap_pop();
		verdict(p.id, p.verdict);
	}
	return 0;
}
