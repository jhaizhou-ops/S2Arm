package org.s2arm.android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** A PID alone does not identify a process after reuse. Pure Java for host verification. */
final class ProcessBirth {
    final int pid;
    final long startTicks, startElapsedMs, startWallMs;

    ProcessBirth(int pid, long ticks, long elapsed, long wall) {
        if (pid <= 0 || ticks <= 0 || elapsed <= 0 || wall <= 0) throw new IllegalArgumentException("invalid process birth");
        this.pid = pid; startTicks = ticks; startElapsedMs = elapsed; startWallMs = wall;
    }

    static long startTicks(String stat, int pid) throws IOException {
        int end = stat.lastIndexOf(')');
        if (!stat.startsWith(pid + " (") || end < 0) throw new IOException("stat PID/comm mismatch");
        String[] fields = stat.substring(end + 1).trim().split("\\s+");
        try { long ticks = Long.parseLong(fields[19]); if (ticks > 0) return ticks; }
        catch (NumberFormatException | IndexOutOfBoundsException error) { throw new IOException("invalid stat startticks",error); }
        throw new IOException("invalid stat startticks");
    }

    byte[] summary() {
        return ("s0-birth:" + pid + ":" + startTicks + ":" + startElapsedMs).getBytes(StandardCharsets.UTF_8);
    }

    String json() {
        return "{\"pid\":" + pid + ",\"startTicks\":" + startTicks + ",\"startElapsedMs\":" + startElapsedMs
            + ",\"startWallMs\":" + startWallMs + "}";
    }

    static ProcessBirth parse(String json) {
        Map<String,Object> m = Json.object(Json.parse(json),"process birth");
        return new ProcessBirth(Math.toIntExact(number(m,"pid")),number(m,"startTicks"),
            number(m,"startElapsedMs"),number(m,"startWallMs"));
    }

    private static long number(Map<String,Object> m, String name) {
        Object value = m.get(name);
        if (!(value instanceof Long)) throw new IllegalArgumentException("invalid process birth " + name);
        return (Long)value;
    }
}
