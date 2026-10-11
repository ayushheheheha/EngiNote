package com.engikode.enginote

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Where recordings are kept: Movies/EngiNote on the tablet's own storage, through MediaStore, so
 * that the Gallery and the Files app show them and they are there for a video editor. The page
 * lists them as a folder (the 'recordings' message in app.js).
 */
object Recordings {
    private const val FOLDER = "Movies/EngiNote"
    private val collection: Uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI

    class Entry(val uri: Uri, val pfd: ParcelFileDescriptor, val name: String)

    /** A note's name as the start of a file name: no characters a file name cannot hold, not too long, never empty. */
    fun safe(title: String): String {
        val clean = title.map { if (it in "/\\:*?\"<>|" || it.isISOControl()) ' ' else it }.joinToString("").trim(' ', '.', '\t', '\n')
        return if (clean.isEmpty()) "EngiNote" else clean.take(60)
    }

    /** A new, empty recording, named for its note and the moment it began. It stays hidden from the
     *  Gallery until finish(). */
    fun create(context: Context, title: String): Entry {
        val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date())
        val name = "${safe(title)} $stamp.mp4"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, FOLDER)
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(collection, values) ?: throw IllegalStateException("the movie file could not be made")
        val pfd = context.contentResolver.openFileDescriptor(uri, "rw")
        if (pfd == null) {
            context.contentResolver.delete(uri, null, null)
            throw IllegalStateException("the movie file could not be opened")
        }
        return Entry(uri, pfd, name)
    }

    fun finish(context: Context, uri: Uri) {
        context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
    }

    fun delete(context: Context, uri: Uri) {
        try {
            context.contentResolver.delete(uri, null, null)
        } catch (e: Exception) { /* not ours to delete, or already gone */ }
    }

    private class Row(val uri: Uri, val name: String, val size: Long, val modified: Long)

    private fun rows(context: Context, name: String? = null): List<Row> {
        val found = ArrayList<Row>()
        val columns = arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DATE_MODIFIED)
        var selection = "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?"
        val args = arrayListOf("$FOLDER/%")
        if (name != null) {
            selection += " AND ${MediaStore.Video.Media.DISPLAY_NAME} = ?"
            args.add(name)
        }
        try {
            context.contentResolver.query(collection, columns, selection, args.toTypedArray(), null)?.use { c ->
                while (c.moveToNext()) {
                    found.add(Row(ContentUris.withAppendedId(collection, c.getLong(0)), c.getString(1), c.getLong(2), c.getLong(3) * 1000))
                }
            }
        } catch (e: Exception) { /* no access: an empty folder */ }
        return found
    }

    /** The recording the page means by `name`, and nothing else, whatever the name says. */
    fun find(context: Context, name: String): Uri? = rows(context, name.substringAfterLast('/')).firstOrNull()?.uri

    /** A small picture of a recording (a frame a second in), made once and kept in the cache folder,
     *  which the system may empty: then it is simply made again. */
    private fun picture(context: Context, row: Row): ByteArray? {
        val kept = File(File(context.cacheDir, "RecordingPictures").also { it.mkdirs() }, "${row.name}.${row.size}.jpg")
        if (kept.exists()) return kept.readBytes()
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, row.uri)
            val frame = retriever.getScaledFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 270)
                ?: retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 270)
                ?: return null
            val out = ByteArrayOutputStream()
            frame.compress(Bitmap.CompressFormat.JPEG, 70, out)
            out.toByteArray().also { kept.writeBytes(it) }
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    /** The list as the page wants it: [{ name, size, modified (ms), picture (a data: URL) }]. Slow
     *  the first time (a frame is picked from each movie): not on the main thread. */
    fun list(context: Context): JSONArray {
        val files = JSONArray()
        for (row in rows(context)) {
            val entry = JSONObject().put("name", row.name).put("size", row.size).put("modified", row.modified)
            picture(context, row)?.let { entry.put("picture", "data:image/jpeg;base64," + Base64.encodeToString(it, Base64.NO_WRAP)) }
            files.put(entry)
        }
        return files
    }
}
