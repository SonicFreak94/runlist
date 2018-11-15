import core.sync.mutex;
import core.thread;
import std.algorithm;
import std.array;
import std.file;
import std.getopt;
import std.parallelism : totalCPUs;
import std.path;
import std.process;
import std.stdio;

shared Mutex io;

class WorkerThread : Thread
{
	private size_t id_;
	private void id(typeof(id_) value) @property
	{
		id_ = value;
	}
	public auto id() const nothrow @property
	{
		return id_;
	}

	Appender!(string[]) data;

	void run()
	{
		for (size_t i; i < data.data.length; i++)
		{
			auto s = data.data[i];

			try
			{
				synchronized (io)
				{
					stdout.writefln(`[%02u] Executing: %s`, id, s);
				}

				Pid pid;

				synchronized pid = spawnShell(s, null, Config.none, null);
				auto result = wait(pid);

				synchronized (io)
				{
					stdout.writefln(`[%02u] "%s" returned: %d signed, %u unsigned, 0x%08X hex`,
					                id, s, result, result, result);
				}
			}
			catch (Exception ex)
			{
				synchronized (io)
				{
					stdout.writefln(`[%02u] Failed: %s`, id, ex.msg);
					continue;
				}
			}
		}
	}

public:
	this(typeof(id_) id)
	{
		super(&run);
		this.id = id;
	}

	void addData(string input)
	{
		data.put(input.idup);
	}

	void addData(string[] input)
	{
		foreach (string s; input)
		{
			addData(s);
		}
	}
}

int main(string[] argv)
{
	size_t threadCount;
	io = cast(shared)(new Mutex());

	try
	{
		const help = getopt(argv,
		                    "threads|t",
		                    "Number of threads to run. By default, this will match the system's reported thread count.",
		                    &threadCount);

		if (help.helpWanted)
		{
			stdout.writeln("Give me a path to a list of commands. Use -t (--threads) to force a thread count.");
			return 0;
		}
	}
	catch (Exception ex)
	{
		stderr.writeln(ex.msg);
		return -1;
	}

	if (!threadCount)
	{
		threadCount = totalCPUs;
	}

	stdout.writeln("Thread count: ", threadCount);

	foreach (string arg; argv[1 .. $])
	{
		if (!exists(arg))
		{
			stderr.writeln("File does not exist: ", arg);
			continue;
		}

		if (!isFile(arg))
		{
			stderr.writeln("Path is not a file: ", arg);
			continue;
		}

		File f = File(arg, "r");

		if (!f.isOpen)
		{
			stderr.writefln("Unable to open file \"%s\" for reading.", arg);
			continue;
		}

		chdir(dirName(arg));

		string[] lines = f.byLineCopy().array;
		f.close();

		if (lines.empty)
		{
			stderr.writeln(arg, " is empty.");
			continue;
		}

		auto count = min(threadCount, lines.length);
		WorkerThread[] threads = new WorkerThread[count];

		foreach (size_t i; 0 .. count)
		{
			threads[i] = new WorkerThread(i + 1);
		}

		foreach (size_t i, string line; lines)
		{
			threads[i % count].addData(line);
		}

		stdout.writeln("Starting threads...");
		threads.each!(x => x.start());

		while (threads.any!(x => x.isRunning))
		{
			bool done;

			foreach (WorkerThread t; threads)
			{
				if (t.isRunning)
				{
					continue;
				}

				done = true;

				try
				{
					t.join(true);
					synchronized (io)
					{
						stdout.writefln("Thread %u has finished.", t.id);
					}
				}
				catch (Exception ex)
				{
					synchronized (io)
					{
						stderr.writefln("Thread %u threw an exception: %s", t.id, ex.msg);
					}
				}
			}

			if (done)
			{
				threads = threads.remove!(x => !x.isRunning);
			}

			Thread.sleep(250.msecs);
		}
	}

	return 0;
}
