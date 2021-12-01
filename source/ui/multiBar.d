module ui.multiBar;

import std.conv : to;
import std.algorithm.searching : canFind;
import std.algorithm.comparison : max;
import std.string : leftJustifier;
import std.stdio : stderr;
import core.time : msecs, Duration;
import progress.bar : Bar;
import ui.duration : formatDuration;

enum BarStatus
{
    NONE,
    STARTED,
    FINISHED
}

class PositionalBar : Bar
{
private:
    BarStatus _status;
public:
    uint position;

    this()
    {
        super();
        this._status = BarStatus.NONE;
    }

    void begin(ulong totalCount)
    {
        auto difference = totalCount - 1 - this.position;
        if (difference > 0)
        {
            file.write("\x1b[" ~ difference.to!string ~ "F");
        }
    }

    override void start()
    {
        super.start();
        this._status = BarStatus.STARTED;
    }

    void end(ulong totalCount)
    {
        auto difference = totalCount - 1 - this.position;
        if (difference > 0)
        {
            file.write("\x1b[" ~ difference.to!string ~ "E");
        }
    }

    void finish(bool isFinalFinish, ulong totalCount)
    {
        this.force_update();
        end(totalCount);
        if (isFinalFinish)
        {
            if (this.hide_cursor)
            {
                file.write("\x1b[?25h");
                file.flush();
            }
            file.writeln();
        }
        this._status = BarStatus.FINISHED;
    }


    @property BarStatus status()
    {
        return this._status;
    }

    override @property real progress()
    {
        if (this.max > 0)
        {
            return super.progress;
        } else
        {
            return 0;
        }
    }

    override @property Duration eta()
    {
        if (this.progress > 0)
        {
            auto ms = this.elapsed.total!"msecs";
            return msecs(cast(long)(ms / this.progress - ms));
        } else
        {
            return Duration.zero;
        }
    }

    @property string remainingTime()
    {
        return formatDuration(this.eta);
    }

}

class MultiBar(T)
{
private:
    PositionalBar[T] bars;
    bool[PositionalBar] finishedBars;
    ulong _totalCount;
    int messageWidth;
    int rowCount = 1;

public:
    this(ulong totalCount = 0, int messageWidth = 0)
    {
        this._totalCount = totalCount;
        this.messageWidth = messageWidth;
        for (int i = 1; i < this.totalCount; i++)
        {
            stderr.writeln();
            this.rowCount++;
        }
    }

    @property ulong length()
    {
        return this.bars.length;
    }

    @property ulong totalCount()
    {
        if (this._totalCount == 0)
        {
            return this.bars.length;
        }
        return this._totalCount;
    }

    PositionalBar get(T id)
    {
        if (id in bars)
        {
            return this.bars[id];
        }
        auto bar = new PositionalBar();
        bar.position = cast(uint)this.bars.length;
        this.bars[id] = bar;
        if (this.messageWidth >= 0)
        {
            this.messageWidth = this.messageWidth.max(cast(int)id.to!string.length);
            bar.message = { return leftJustifier(id.to!string, this.messageWidth).to!string; };
        } else
        {
            bar.message = { return id; };
        }
        return bar;
    }

    PositionalBar reset(T id)
    {
        uint position = 0;
        if (id in this.bars)
        {
            auto bar = this.bars[id];
            position = bar.position;
            this.finishedBars.remove(bar);
            this.bars.remove(id);
        }

        auto bar = this.get(id);
        bar.position = position;
        return bar;
    }

    void start(PositionalBar bar)
    {
        assert(this.bars.values.canFind(bar));

        while (cast(long)bar.position + 1 - this.rowCount > 0)
        {
            stderr.writeln();
            this.rowCount++;
        }

        bar.begin(this.rowCount);
        bar.start();
        bar.end(this.rowCount);
    }

    void finish(PositionalBar bar, void delegate(PositionalBar bar) extra = null)
    {
        assert(this.bars.values.canFind(bar));

        if (bar !in this.finishedBars)
        {
            bar.begin(this.rowCount);
            if (extra)
            {
                extra(bar);
            }
            this.finishedBars[bar] = true;
            bar.finish(this.finishedBars.length >= this.totalCount, this.rowCount);
        }
    }

    void goto_index(PositionalBar bar, ulong index)
    {
        assert(this.bars.values.canFind(bar));

        bar.begin(this.rowCount);
        bar.goto_index(index);
        bar.end(this.rowCount);
    }
}
