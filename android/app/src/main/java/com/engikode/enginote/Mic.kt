package com.engikode.enginote

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * The microphone, listened to once, for both its uses: the mic check (the page shows how loud the
 * sound is) and a recording (the sound goes to the movie). There is only ever the one listening:
 * a recording that starts while a check is on joins it, and one that ends leaves it running for the check.
 *
 * "Enhanced" listens the way calls do, through the system's noise suppression, echo cancelling
 * and gain control, where the tablet has them.
 *
 * None of this can be run off the device: it is only proven by recording on the tablet.
 */
class Mic(private val onLevel: (Double) -> Unit, private val onFailed: (String) -> Unit) {
    companion object {
        const val RATE = 44100
        private const val CHUNK = 2205 // samples: a twentieth of a second
        // What the page draws as silence and as full height, in decibels below the loudest sound the
        // microphone can report: the knobs to turn if the bars sit too low or too high on the real tablet.
        private const val QUIETEST = -55.0
        private const val LOUDEST = -5.0
    }

    /** Sound for a recording: 16-bit mono PCM, how many bytes, and when (System.nanoTime) the last of it was heard.
     *  Called on the listening thread. */
    @Volatile var sink: ((ByteArray, Int, Long) -> Unit)? = null
    /** The page is showing the sound. */
    @Volatile var checking = false

    private val main = Handler(Looper.getMainLooper())
    private var thread: Thread? = null
    @Volatile private var running = false
    private var enhanced = false

    /** Listen, the enhanced way or not. False if the microphone could not be started. A listening
     *  that is feeding a recording is never restarted, whatever the way asked for. */
    @SuppressLint("MissingPermission") // MainActivity asks the user first
    @Synchronized
    fun start(enhance: Boolean): Boolean {
        if (running) {
            if (enhance == enhanced || sink != null) return true
            stop()
        }
        val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) return false
        val record = try {
            AudioRecord(
                if (enhance) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC,
                RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, max(minimum * 2, CHUNK * 2 * 8),
            )
        } catch (e: Exception) {
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        val effects = ArrayList<AudioEffect>() // the listening's own: let go of when it ends
        if (enhance) {
            val session = record.audioSessionId
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session)?.let { it.enabled = true; effects.add(it) }
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session)?.let { it.enabled = true; effects.add(it) }
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session)?.let { it.enabled = true; effects.add(it) }
        }
        try {
            record.startRecording()
        } catch (e: Exception) {
            record.release()
            effects.forEach { it.release() }
            effects.clear()
            return false
        }
        enhanced = enhance
        running = true
        thread = Thread { listen(record, effects) }.also { it.name = "EngiNote microphone"; it.start() }
        return true
    }

    /** Let go of the microphone, unless a check or a recording still wants it. */
    @Synchronized
    fun stopIfUnwanted() {
        if (!checking && sink == null) stop()
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(500)
        thread = null
    }

    private fun listen(record: AudioRecord, effects: List<AudioEffect>) {
        val buffer = ByteArray(CHUNK * 2)
        while (running) {
            val n = record.read(buffer, 0, buffer.size)
            val at = System.nanoTime()
            if (n < 0) {
                running = false
                main.post { onFailed("The microphone stopped working.") }
                break
            }
            if (n == 0) continue
            sink?.invoke(buffer, n, at)
            if (checking) {
                var sum = 0.0
                var i = 0
                while (i + 1 < n) {
                    val s = (buffer[i].toInt() and 0xff) or (buffer[i + 1].toInt() shl 8) // signed 16-bit, little-endian
                    sum += s.toDouble() * s
                    i += 2
                }
                val rms = sqrt(sum / (n / 2))
                val db = 20 * log10(max(rms, 1.0) / 32768.0)
                val level = ((db - QUIETEST) / (LOUDEST - QUIETEST)).coerceIn(0.0, 1.0)
                main.post { onLevel(level) }
            }
        }
        try { record.stop() } catch (e: Exception) { /* already stopped */ }
        record.release()
        effects.forEach { it.release() }
    }
}
