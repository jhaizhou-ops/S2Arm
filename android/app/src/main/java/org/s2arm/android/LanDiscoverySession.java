package org.s2arm.android;

import java.util.LinkedHashMap;
import java.util.Map;

/** NSD callback admission and peer lifetime; election remains in s2a_lan_elect. */
final class LanDiscoverySession {
    interface Changed { void accept(Peer[] peers); }
    static final class Peer {
        final String name;
        final String address;
        final int port;
        Peer(String name, String address, int port) { this.name = name; this.address = address; this.port = port; }
    }
    static final class Resolve {
        final long generation;
        final String name;
        private String address;
        private int port;
        Resolve(long generation, String name) { this.generation = generation; this.name = name; }
    }

    private final Changed changed;
    private final Map<String, Resolve> peers = new LinkedHashMap<>();
    private long generation;
    private boolean active;

    LanDiscoverySession(Changed changed) { this.changed = changed; }

    synchronized long start() {
        if (!active) { generation++; active = true; peers.clear(); }
        return generation;
    }

    /** Return a ticket once per service incarnation, not once per name forever. */
    synchronized Resolve found(long session, String name) {
        if (!active || session != generation || peers.containsKey(name)) return null;
        Resolve ticket = new Resolve(session, name);
        peers.put(name, ticket);
        return ticket;
    }

    synchronized void resolved(Resolve ticket, String address, int port) {
        if (!current(ticket) || address == null || port < 1 || port > 65535 || (address.equals(ticket.address) && port == ticket.port)) return;
        ticket.address = address;
        ticket.port = port;
        publish();
    }

    synchronized void failed(Resolve ticket) {
        if (current(ticket) && ticket.address == null) peers.remove(ticket.name);
    }

    synchronized void lost(long session, String name) {
        if (!active || session != generation) return;
        Resolve removed = peers.remove(name);
        if (removed != null && removed.address != null) publish();
    }

    /**
     * Invalidate before releasing platform discovery resources. The same monitor guards callbacks,
     * so no Changed invocation is admitted after this returns (including delayed resolve results).
     * Changed must be nonblocking and must not wait for another thread to call this object.
     */
    synchronized void stop() {
        active = false;
        peers.clear();
    }

    private boolean current(Resolve ticket) {
        return active && ticket != null && ticket.generation == generation
            && peers.get(ticket.name) == ticket;
    }

    private void publish() {
        Peer[] snapshot = peers.values().stream().filter(p -> p.address != null)
            .map(p -> new Peer(p.name, p.address, p.port)).toArray(Peer[]::new);
        changed.accept(snapshot);
    }
}
