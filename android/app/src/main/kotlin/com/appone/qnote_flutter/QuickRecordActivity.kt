package com.appone.qnote_flutter

import android.Manifest
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

class QuickRecordActivity : Activity() {
    private lateinit var editContent: EditText
    private lateinit var containerPhotos: LinearLayout
    private lateinit var scrollPhotos: HorizontalScrollView
    private lateinit var btnPhoto: ImageButton
    private lateinit var btnCamera: ImageButton
    private lateinit var btnCancel: Button
    private lateinit var btnSend: Button

    private val selectedPhotos = ArrayList<String>()
    private var tempCameraFile: File? = null

    companion object {
        const val REQ_CAMERA = 1001
        const val REQ_GALLERY = 1002
        const val REQ_CAMERA_PERM = 2001
        const val REQ_GALLERY_PERM = 2002
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_quick_record)

        initViews()
        handleIncomingIntent(intent)
    }

    private fun initViews() {
        editContent = findViewById(R.id.edit_record_content)
        containerPhotos = findViewById(R.id.container_photos_preview)
        scrollPhotos = findViewById(R.id.scroll_photos_preview)
        btnPhoto = findViewById(R.id.btn_dialog_photo)
        btnCamera = findViewById(R.id.btn_dialog_camera)
        btnCancel = findViewById(R.id.btn_dialog_cancel)
        btnSend = findViewById(R.id.btn_dialog_send)

        btnCancel.setOnClickListener { finish() }
        btnSend.setOnClickListener { sendRecord() }

        btnCamera.setOnClickListener { checkCameraPermissionAndOpen() }
        btnPhoto.setOnClickListener { checkGalleryPermissionAndOpen() }

        findViewById<FrameLayout>(R.id.layout_root).setOnClickListener { finish() }

        // 自动聚焦并弹出软键盘
        editContent.requestFocus()
        editContent.postDelayed({
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showSoftInput(editContent, InputMethodManager.SHOW_IMPLICIT)
        }, 200)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        val clickAction = intent?.getStringExtra("click_action")
        when (clickAction) {
            "camera" -> checkCameraPermissionAndOpen()
            "photo" -> checkGalleryPermissionAndOpen()
        }
    }

    private fun checkCameraPermissionAndOpen() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQ_CAMERA_PERM)
        } else {
            openCamera()
        }
    }

    private fun checkGalleryPermissionAndOpen() {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

        if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(permission), REQ_GALLERY_PERM)
        } else {
            openGallery()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            when (requestCode) {
                REQ_CAMERA_PERM -> openCamera()
                REQ_GALLERY_PERM -> openGallery()
            }
        } else {
            Toast.makeText(this, "权限被拒绝，无法使用该功能", Toast.LENGTH_SHORT).show()
        }
    }

    private fun openCamera() {
        if (selectedPhotos.size >= 3) {
            Toast.makeText(this, "最多只能添加 3 张图片", Toast.LENGTH_SHORT).show()
            return
        }
        try {
            val cacheDir = File(cacheDir, "camera_pics")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            val tempFile = File.createTempFile("cam_${System.currentTimeMillis()}", ".jpg", cacheDir)
            tempCameraFile = tempFile

            val authority = "${packageName}.fileprovider"
            val photoURI = FileProvider.getUriForFile(this, authority, tempFile)

            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, photoURI)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            startActivityForResult(intent, REQ_CAMERA)
        } catch (e: Exception) {
            e.printStackTrace()
            Toast.makeText(this, "打开相机失败: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun openGallery() {
        if (selectedPhotos.size >= 3) {
            Toast.makeText(this, "最多只能添加 3 张图片", Toast.LENGTH_SHORT).show()
            return
        }
        val intent = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
        startActivityForResult(intent, REQ_GALLERY)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == RESULT_OK) {
            when (requestCode) {
                REQ_CAMERA -> {
                    val file = tempCameraFile
                    if (file != null && file.exists()) {
                        addPhoto(file.absolutePath)
                    }
                }
                REQ_GALLERY -> {
                    val uri = data?.data
                    if (uri != null) {
                        val path = copyUriToCache(uri)
                        if (path != null) {
                            addPhoto(path)
                        }
                    }
                }
            }
        }
    }

    private fun copyUriToCache(uri: Uri): String? {
        try {
            val cacheDir = File(cacheDir, "gallery_pics")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            val tempFile = File.createTempFile("gal_${System.currentTimeMillis()}", ".jpg", cacheDir)
            val inputStream = contentResolver.openInputStream(uri) ?: return null
            val outputStream = FileOutputStream(tempFile)
            val buffer = ByteArray(4096)
            var bytesRead: Int
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
            }
            outputStream.close()
            inputStream.close()
            return tempFile.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        }
    }

    private fun addPhoto(path: String) {
        selectedPhotos.add(path)
        updatePhotosPreview()
    }

    private fun removePhoto(path: String) {
        selectedPhotos.remove(path)
        updatePhotosPreview()
    }

    private fun updatePhotosPreview() {
        containerPhotos.removeAllViews()
        if (selectedPhotos.isEmpty()) {
            scrollPhotos.visibility = View.GONE
            return
        }
        scrollPhotos.visibility = View.VISIBLE

        val size = (64 * resources.displayMetrics.density).toInt()
        val margin = (8 * resources.displayMetrics.density).toInt()

        for (path in selectedPhotos) {
            // 创建每一个图片的 Preview FrameLayout (带删除按钮)
            val frame = FrameLayout(this).apply {
                val params = LinearLayout.LayoutParams(size, size).apply {
                    setMargins(0, 0, margin, 0)
                }
                layoutParams = params
            }

            val iv = ImageView(this).apply {
                layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageURI(Uri.fromFile(File(path)))
            }
            frame.addView(iv)

            // 删除按钮
            val btnDel = ImageButton(this).apply {
                val btnSize = (18 * resources.displayMetrics.density).toInt()
                layoutParams = FrameLayout.LayoutParams(btnSize, btnSize).apply {
                    gravity = Gravity.TOP or Gravity.RIGHT
                }
                setBackgroundColor(Color.parseColor("#99000000"))
                setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
                scaleType = ImageView.ScaleType.FIT_CENTER
                setColorFilter(Color.WHITE)
                setPadding(2, 2, 2, 2)
                setOnClickListener { removePhoto(path) }
            }
            frame.addView(btnDel)

            containerPhotos.addView(frame)
        }
    }

    private fun sendRecord() {
        val content = editContent.text.toString().trim()
        if (content.isEmpty() && selectedPhotos.isEmpty()) {
            Toast.makeText(this, "内容不能为空", Toast.LENGTH_SHORT).show()
            return
        }

        // 异步写入数据库，保证流畅性
        Thread {
            var db: SQLiteDatabase? = null
            try {
                val dbFile = getDatabasePath("qnote.db")
                if (!dbFile.exists()) return@Thread

                db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)

                val id = UUID.randomUUID().toString()
                val nowStr = getISO8601Timestamp()

                // 1. 将临时图片拷贝到 images/diary 目录下并保存新路径
                val finalPhotoPaths = ArrayList<String>()
                val imagesDir = File(filesDir, "images/diary")
                if (!imagesDir.exists()) imagesDir.mkdirs()

                for (photoPath in selectedPhotos) {
                    val srcFile = File(photoPath)
                    if (srcFile.exists()) {
                        val destFile = File(imagesDir, "${UUID.randomUUID()}.jpg")
                        srcFile.copyTo(destFile)
                        finalPhotoPaths.add(destFile.absolutePath)
                    }
                }

                val title = if (content.length > 15) content.substring(0, 15) else if (content.isNotEmpty()) content else "快速记录"
                val photosJson = buildString {
                    append("[")
                    for (i in finalPhotoPaths.indices) {
                        append("\"").append(finalPhotoPaths[i]).append("\"")
                        if (i < finalPhotoPaths.size - 1) append(",")
                    }
                    append("]")
                }

                // 2. 插入到 diary_records
                val values = ContentValues().apply {
                    put("id", id)
                    put("title", title)
                    put("content", content)
                    put("mood", 3)
                    put("weather", "")
                    put("tags", "[]")
                    put("display_tag", "")
                    put("photos", photosJson)
                    put("color_mark", "")
                    put("created_at", nowStr)
                    put("updated_at", nowStr)
                    put("time", nowStr)
                    put("is_deleted", 0)
                }
                db.insert("diary_records", null, values)

                // 3. 构造完整 JSON 并记录 sync_log
                val recordJson = buildRecordJson(
                    id = id,
                    title = title,
                    content = content,
                    photosJson = photosJson,
                    nowStr = nowStr
                )

                val logValues = ContentValues().apply {
                    put("table_name", "diary_records")
                    put("record_id", id)
                    put("operation", "insert")
                    put("data", recordJson)
                    put("timestamp", nowStr)
                }
                db.insert("sync_log", null, logValues)

                // 清理缓存
                selectedPhotos.forEach { File(it).delete() }

                runOnUiThread {
                    Toast.makeText(this, "记录成功", Toast.LENGTH_SHORT).show()
                    
                    // 通知桌面快捷记录小组件数据有更新
                    val widgetManager = AppWidgetManager.getInstance(this@QuickRecordActivity)
                    val component = ComponentName(this@QuickRecordActivity, QuickRecordWidgetProvider::class.java)
                    val widgetIds = widgetManager.getAppWidgetIds(component)
                    
                    val updateIntent = Intent(this@QuickRecordActivity, QuickRecordWidgetProvider::class.java).apply {
                        action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, widgetIds)
                    }
                    sendBroadcast(updateIntent)

                    finish()
                }
            } catch (e: Exception) {
                e.printStackTrace()
                runOnUiThread {
                    Toast.makeText(this@QuickRecordActivity, "写入失败: ${e.message}", Toast.LENGTH_SHORT).show()
                }
            } finally {
                db?.close()
            }
        }.start()
    }

    private fun getISO8601Timestamp(): String {
        val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
        df.timeZone = TimeZone.getDefault()
        return df.format(Date())
    }

    private fun buildRecordJson(
        id: String,
        title: String,
        content: String,
        photosJson: String,
        nowStr: String
    ): String {
        // 转义 JSON 中的字符串换行与双引号
        val escapedContent = content.replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
        val escapedTitle = title.replace("\"", "\\\"")
        
        return buildString {
            append("{")
            append("\"id\":\"$id\",")
            append("\"title\":\"$escapedTitle\",")
            append("\"content\":\"$escapedContent\",")
            append("\"mood\":3,")
            append("\"weather\":\"\",")
            append("\"tags\":\"[]\",")
            append("\"display_tag\":\"\",")
            append("\"photos\":\"${photosJson.replace("\"", "\\\"")}\",") // toMap 中 photos 字段存的是 JSON 序列化字符串本身
            append("\"color_mark\":\"\",")
            append("\"created_at\":\"$nowStr\",")
            append("\"updated_at\":\"$nowStr\",")
            append("\"time\":\"$nowStr\",")
            append("\"is_deleted\":0")
            append("}")
        }
    }
}
