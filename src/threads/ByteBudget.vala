/* SPDX-FileCopyrightText: 2026 Shotwell contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

// Limits the bytes that are held by work that has been started but is not finished.
//
// A producer thread calls acquire() with the size of what it has produced, and blocks while too
// much is still held. Whoever finishes with that data calls release() with the same size, from
// any thread. A request is always granted when nothing is held, so one item that is larger than the
// whole limit cannot block for ever.
public class ByteBudget {
    private Mutex mutex = Mutex();
    private Cond cond = Cond();
    private int64 limit;
    private int64 held = 0;

    public ByteBudget(int64 limit) {
        this.limit = limit;
    }

    public void acquire(int64 bytes) {
        mutex.lock();
        while (held > 0 && held + bytes > limit)
            cond.wait(mutex);
        held += bytes;
        mutex.unlock();
    }

    public void release(int64 bytes) {
        mutex.lock();
        held -= bytes;
        cond.broadcast();
        mutex.unlock();
    }

    public int64 get_held() {
        mutex.lock();
        int64 result = held;
        mutex.unlock();

        return result;
    }
}
