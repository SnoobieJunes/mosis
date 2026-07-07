package org.conduit.core.wire

import java.io.ByteArrayOutputStream

/** Encoded video frame: parameter sets travel with every keyframe. */
data class EncodedVideoFrame(val isKeyframe: Boolean, val parameterSets: List<ByteArray>, val sampleData: ByteArray)

/** Packs/unpacks the ScreenFrame.data blob, matching Swift + Go:
 *  paramCount u8 | [len u32be | bytes]... | sampleData. */
object ScreenPacking {
    private const val MAX_PARAM_SETS = 8

    fun pack(f: EncodedVideoFrame): ByteArray = ByteArrayOutputStream().apply {
        val count = minOf(f.parameterSets.size, MAX_PARAM_SETS)
        write(count)
        for (i in 0 until count) {
            val set = f.parameterSets[i]
            write(set.size ushr 24 and 0xFF); write(set.size ushr 16 and 0xFF)
            write(set.size ushr 8 and 0xFF); write(set.size and 0xFF)
            write(set)
        }
        write(f.sampleData)
    }.toByteArray()

    fun unpack(data: ByteArray, isKeyframe: Boolean): EncodedVideoFrame {
        require(data.isNotEmpty()) { "truncated packed screen frame" }
        val count = data[0].toInt() and 0xFF
        require(count <= MAX_PARAM_SETS) { "too many parameter sets" }
        var cursor = 1
        val sets = ArrayList<ByteArray>(count)
        repeat(count) {
            require(cursor + 4 <= data.size) { "truncated" }
            var len = 0
            for (i in 0 until 4) { len = len shl 8 or (data[cursor + i].toInt() and 0xFF) }
            cursor += 4
            require(cursor + len <= data.size) { "truncated" }
            sets.add(data.copyOfRange(cursor, cursor + len))
            cursor += len
        }
        return EncodedVideoFrame(isKeyframe, sets, data.copyOfRange(cursor, data.size))
    }
}
