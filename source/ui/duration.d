module ui.duration;

import std.conv : to;
import core.time : Duration;


string formatDuration(Duration duration)
{
    auto time = duration.split!("hours", "minutes", "seconds", "msecs");
    string prefix = ", eta ";
    string timeString = "";
    if (time.hours == 1)
    {
        timeString ~= time.hours.to!string ~ " hour";
    } else if (time.hours > 0)
    {
        timeString ~= time.hours.to!string ~ " hours";
    }

    if (time.msecs >= 500)
    {
        time.seconds += 1;
    }

    if (time.seconds >= 30)
    {
        time.minutes += 1;
    }

    if (time.hours == 0 && time.minutes == 1)
    {
        timeString ~= "about a minute";
    } else if (time.minutes > 0)
    {
        if (time.hours > 0)
        {
        timeString ~= " and ";
        }
        timeString ~= "~" ~ time.minutes.to!string;
        if (time.minutes == 1)
        {
        timeString ~= " minute";
        } else
        {
        timeString ~= " minutes";
        }
    } else if (time.hours > 0)
    {
        timeString = "~" ~ timeString;
    } else if (time.seconds > 0 || time.msecs > 0)
    {
        timeString ~= "just a few seconds";
    } else if (time.seconds == 0 && time.msecs == 0)
    {
        return "";
    }

    return prefix ~ timeString;
}
