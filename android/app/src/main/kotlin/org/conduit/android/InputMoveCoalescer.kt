package org.conduit.android

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Coalesces pointer motion so a continuous drag emits one wire frame per tick
 * (~120 Hz) instead of one per pointer sample — the Android counterpart of the
 * Swift `InputCoalescer`. The first move after idle flushes immediately
 * (leading edge), so a single small nudge pays no coalescing delay; only
 * sustained motion is batched. Discrete events (clicks, keys) must call
 * [flush] before sending so ordering is preserved.
 */
class InputMoveCoalescer(
    scope: CoroutineScope,
    private val tickMillis: Long = 8,
    private val send: (peerId: String, dx: Double, dy: Double) -> Unit,
) {
    private class Delta(var dx: Double = 0.0, var dy: Double = 0.0)

    private val pending = HashMap<String, Delta>()
    private val lock = Any()
    private val wake = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch {
            while (isActive) {
                wake.receive()
                while (flushOnce()) delay(tickMillis)
            }
        }
    }

    fun move(peerId: String, dx: Double, dy: Double) {
        synchronized(lock) {
            val d = pending.getOrPut(peerId) { Delta() }
            d.dx += dx
            d.dy += dy
        }
        wake.trySend(Unit)
    }

    /** Send any accumulated motion now — call before a discrete event. */
    fun flush() {
        flushOnce()
    }

    private fun flushOnce(): Boolean {
        val batch: List<Pair<String, Delta>>
        synchronized(lock) {
            if (pending.isEmpty()) return false
            batch = pending.toList()
            pending.clear()
        }
        for ((peerId, d) in batch) {
            if (d.dx != 0.0 || d.dy != 0.0) send(peerId, d.dx, d.dy)
        }
        return true
    }
}
