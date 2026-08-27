#import <Foundation/Foundation.h>
#import <unistd.h>
#import <string>
#import <cstdarg>
#import <cstdio>
#import <cstring>
#import <csignal>
#import <ctime>
#import <execinfo.h>
#import <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cstdlib>
#include <exception>
#include <errno.h>

extern "C" void ios_log(const char *fmt, ...);
extern "C" void ios_log_open(void);
extern "C" void ios_install_crash_handler(void);
extern "C" const char *ios_documents_path(void);

// Install logging + crash capture as early as possible (at dynamic load),
// before reVC's own startup code runs, so even early crashes are captured.
__attribute__((constructor))
static void ios_early_init(void) {
	ios_log_open();
	ios_log("=== reVC iOS early init (constructor) ===");

	// reVC resolves ALL game data (TEXT/AMERICAN.GXT, MODELS/*, DATA/*, ...)
	// relative to the process CWD. On iOS the CWD is the app bundle, where no
	// game data lives. Point CWD at the gamefiles folder the user dropped into
	// the app's Documents (iTunes File Sharing -> reVC -> gamefiles) so the
	// engine actually finds the data instead of fopen(NULL) -> SIGSEGV.
		const char *docs = ios_documents_path();
	if (docs && *docs) {
		char gf[2048];
		snprintf(gf, sizeof(gf), "%s/gamefiles", docs);
		if (access(gf, F_OK) == 0) {
			setenv("GAMEFILES", gf, 1);
			if (chdir(gf) == 0) ios_log("chdir -> %s", gf);
			else ios_log("chdir(%s) FAILED: %s", gf, strerror(errno));
		} else if (access(docs, F_OK) == 0) {
			setenv("GAMEFILES", docs, 1);
			if (chdir(docs) == 0) ios_log("chdir -> %s (no gamefiles subdir)", docs);
			else ios_log("chdir(%s) FAILED: %s", docs, strerror(errno));
		}
	}

	ios_install_crash_handler();
	ios_log("crash handler installed");
}

extern "C" const char *
ios_resource_path(void)
{
	static std::string path;
	if (path.empty()) {
		NSString *res = [[NSBundle mainBundle] resourcePath];
		path = res ? std::string([res UTF8String]) : std::string(".");
	}
	return path.c_str();
}

extern "C" const char *
ios_documents_path(void)
{
	static std::string path;
	if (path.empty()) {
		NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		path = (dirs.count > 0) ? std::string([dirs[0] UTF8String]) : std::string(".");
	}
	return path.c_str();
}

static FILE *g_logFile = nil;
static int   g_logFd = -1;

extern "C" void
ios_log_open(void)
{
	if (g_logFile)
		return;
	char p[1024];
	snprintf(p, sizeof(p), "%s/gamelog.txt", ios_documents_path());
	g_logFile = fopen(p, "w");
	g_logFd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (g_logFile) {
		time_t t = time(nil);
		char tb[32];
		strftime(tb, sizeof(tb), "%Y-%m-%d %H:%M:%S", localtime(&t));
		fprintf(g_logFile, "==== gamelog started %s ====\n", tb);
		fflush(g_logFile);
		// Capture engine stdout/stderr (reVC prints errors via printf) into the same log.
		freopen(p, "a", stdout);
		freopen(p, "a", stderr);
	}
}

extern "C" void
ios_log(const char *fmt, ...)
{
	if (!g_logFile)
		ios_log_open();
	if (!g_logFile)
		return;

	time_t t = time(nil);
	char tb[16];
	strftime(tb, sizeof(tb), "%H:%M:%S", localtime(&t));
	fprintf(g_logFile, "[%s] ", tb);

	va_list ap;
	va_start(ap, fmt);
	vfprintf(g_logFile, fmt, ap);
	va_end(ap);

	fputc('\n', g_logFile);
	fflush(g_logFile);
}

extern "C" void
ios_log_raw(const char *s)
{
	if (!g_logFile)
		ios_log_open();
	if (!g_logFile)
		return;
	fprintf(g_logFile, "%s\n", s);
	fflush(g_logFile);
}

static void
ios_fd_raw(const char *s)
{
	if (g_logFd < 0) return;
	if (s && *s) write(g_logFd, s, strlen(s));
	write(g_logFd, "\n", 1);
}

static void
ios_fd_fmt(const char *fmt, ...)
{
	if (g_logFd < 0) return;
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	ios_fd_raw(buf);
}

static void
ios_dump_backtrace_fd(void)
{
	void *bt[64];
	int n = backtrace(bt, 64);
	ios_fd_fmt("---- backtrace (%d frames) ----", n);
	char **syms = backtrace_symbols(bt, n);
	for (int i = 0; i < n; i++) {
		Dl_info info;
		if (dladdr(bt[i], &info) && info.dli_fname) {
			const char *base = strrchr(info.dli_fname, '/');
			base = base ? base + 1 : info.dli_fname;
			unsigned long off = (unsigned long)bt[i] - (unsigned long)info.dli_fbase;
			if (info.dli_sname)
				ios_fd_fmt("#%02d %s  (%s + 0x%lx)  %s", i, syms ? syms[i] : "?", base, off, info.dli_sname);
			else
				ios_fd_fmt("#%02d %s  (%s + 0x%lx)", i, syms ? syms[i] : "?", base, off);
		} else {
			ios_fd_fmt("#%02d %s", i, syms ? syms[i] : "?");
		}
	}
	free(syms);
}

static volatile sig_atomic_t g_crashing = 0;

static void
ios_signal_handler(int signum, siginfo_t *info, void *ctx)
{
	if (g_crashing) {
		signal(signum, SIG_DFL);
		raise(signum);
		return;
	}
	g_crashing = 1;
	// Write to a raw fd (NOT stdio) so we never deadlock on the stdio lock
	// the crashing thread may already hold (e.g. a crash inside fread()).
	ios_fd_fmt("\n!!!! CRASH: signal %d at address %p !!!!", signum, info ? info->si_addr : nil);
	ios_dump_backtrace_fd();
	ios_fd_raw("!!!! end of crash report !!!!");
	// restore default and re-raise so the OS still generates its own crash report
	signal(signum, SIG_DFL);
	raise(signum);
}

static void
ios_ns_exception_handler(NSException *exception)
{
	if (g_crashing) return;
	g_crashing = 1;
	ios_fd_raw("\n!!!! NSException !!!!");
	if (exception.name)   ios_fd_fmt("name: %s", exception.name.UTF8String);
	if (exception.reason) ios_fd_fmt("reason: %s", exception.reason.UTF8String);
	NSString *stack = exception.callStackSymbols ? [exception.callStackSymbols componentsJoinedByString:@"\n"] : nil;
	if (stack) ios_fd_raw(stack.UTF8String);
	ios_fd_raw("!!!! end of exception report !!!!");
}

static void
ios_atexit(void)
{
	if (g_crashing) return;
	ios_fd_raw("---- normal exit (atexit) ----");
}

static void
ios_terminate(void)
{
	if (g_crashing) return;
	g_crashing = 1;
	ios_fd_raw("\n!!!! std::terminate called (uncaught C++ exception) !!!!");
	ios_dump_backtrace_fd();
	ios_fd_raw("!!!! end of terminate report !!!!");
	abort();
}

extern "C" void
ios_install_crash_handler(void)
{
	ios_log(">>> ios_install_crash_handler called");
	NSSetUncaughtExceptionHandler(ios_ns_exception_handler);
	std::set_terminate(ios_terminate);
	atexit(ios_atexit);

	// alternate signal stack so we survive stack overflows too
	static char sigstack[SIGSTKSZ * 4];
	stack_t ss;
	ss.ss_sp = sigstack;
	ss.ss_size = sizeof(sigstack);
	ss.ss_flags = 0;
	sigaltstack(&ss, nil);

	struct sigaction act;
	memset(&act, 0, sizeof(act));
	act.sa_sigaction = ios_signal_handler;
	act.sa_flags = SA_SIGINFO | SA_ONSTACK;
	const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGPIPE };
	for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
		sigaction(sigs[i], &act, nil);
}
