package com.appone.qnote_flutter

import android.app.AppOpsManager
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.provider.Settings
import java.io.ByteArrayOutputStream
import java.util.Calendar

class UsageStatsHelper(private val context: Context) {

    private val usageStatsManager =
        context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
    private val packageManager: PackageManager = context.packageManager
    private val iconCache = mutableMapOf<String, ByteArray?>()
    private val labelCache = mutableMapOf<String, String>()

    /**
     * 检查用户是否已授予使用情况访问权限
     */
    fun hasUsagePermission(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /**
     * 跳转至系统使用情况访问设置页
     */
    fun openUsageSettings() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    /**
     * 获取指定时间范围内的各 App 使用数据列表
     * @param startTime 毫秒时间戳
     * @param endTime 毫秒时间戳
     * @param limit 返回最多前 N 个应用（按使用时长倒序）
     * @param includeIcons 是否获取应用图标字节（列表或卡片若无需图标可设为 false 以大幅减轻 IPC 负担）
     */
    fun getUsageStats(
        startTime: Long,
        endTime: Long,
        limit: Int = 30,
        includeIcons: Boolean = true
    ): List<Map<String, Any?>> {
        val manager = usageStatsManager ?: return emptyList()
        val statsList = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startTime,
            endTime
        ) ?: return emptyList()

        // 桌面/Launcher 包名获取（避免将其错误归入普通应用占用）
        val homePackages = getLauncherPackages()

        // 聚合相同包名的前台使用时长
        val aggregated = mutableMapOf<String, Long>()
        val lastUsedMap = mutableMapOf<String, Long>()

        for (stats in statsList) {
            val pkg = stats.packageName
            if (pkg.isNullOrBlank() || pkg == "android" || homePackages.contains(pkg)) {
                continue
            }
            val time = stats.totalTimeInForeground
            if (time > 0) {
                aggregated[pkg] = (aggregated[pkg] ?: 0L) + time
                val last = stats.lastTimeUsed
                if (last > (lastUsedMap[pkg] ?: 0L)) {
                    lastUsedMap[pkg] = last
                }
            }
        }

        // 排序并筛选出时长 > 10 秒的应用
        val sortedList = aggregated.filter { it.value >= 10_000L }
            .toList()
            .sortedByDescending { it.second }
            .take(limit)

        val result = mutableListOf<Map<String, Any?>>()
        for ((pkg, duration) in sortedList) {
            val appName = getAppLabel(pkg)
            val iconBytes = if (includeIcons) getAppIconBytes(pkg) else null
            result.add(
                mapOf(
                    "packageName" to pkg,
                    "appName" to appName,
                    "totalTimeInForeground" to duration,
                    "lastTimeUsed" to (lastUsedMap[pkg] ?: 0L),
                    "icon" to iconBytes
                )
            )
        }
        return result
    }

    /**
     * 获取最近 7 天的每日屏幕总使用时长（按天统计，供柱状图展示）
     */
    fun getWeeklyScreenTime(): List<Map<String, Any>> {
        val result = mutableListOf<Map<String, Any>>()
        val calendar = Calendar.getInstance()
        
        // 归一化到今天 23:59:59.999
        calendar.set(Calendar.HOUR_OF_DAY, 23)
        calendar.set(Calendar.MINUTE, 59)
        calendar.set(Calendar.SECOND, 59)
        calendar.set(Calendar.MILLISECOND, 999)

        // 倒推 7 天（从 6 天前到今天）
        for (i in 6 downTo 0) {
            val dayCal = Calendar.getInstance().apply {
                timeInMillis = calendar.timeInMillis
                add(Calendar.DAY_OF_YEAR, -i)
            }
            
            dayCal.set(Calendar.HOUR_OF_DAY, 0)
            dayCal.set(Calendar.MINUTE, 0)
            dayCal.set(Calendar.SECOND, 0)
            dayCal.set(Calendar.MILLISECOND, 0)
            val dayStart = dayCal.timeInMillis

            dayCal.set(Calendar.HOUR_OF_DAY, 23)
            dayCal.set(Calendar.MINUTE, 59)
            dayCal.set(Calendar.SECOND, 59)
            dayCal.set(Calendar.MILLISECOND, 999)
            val dayEnd = if (i == 0) System.currentTimeMillis() else dayCal.timeInMillis

            val dayTotal = calculateTotalScreenTime(dayStart, dayEnd)
            result.add(
                mapOf(
                    "date" to dayStart,
                    "totalTime" to dayTotal,
                    "dayOfWeek" to dayCal.get(Calendar.DAY_OF_WEEK),
                    "isToday" to (i == 0)
                )
            )
        }
        return result
    }

    /**
     * 获取区间内逐日的屏幕总时长与各应用明细。
     *
     * 与 getWeeklyScreenTime 的关键差别：只做**一次** queryUsageStats，再按自然日分桶，
     * 因此回填 14~31 天不会线性放大 IPC 开销。每日总量不过滤 10 秒门槛，
     * 与 calculateTotalScreenTime 口径一致，保证柱状图与大数字对得上；
     * 应用明细则沿用 getUsageStats 的 10 秒门槛与倒序截断。
     *
     * @param startTime 区间起点毫秒时间戳
     * @param endTime 区间终点毫秒时间戳
     * @param appLimitPerDay 每日最多返回几个应用（供落库与区间累计 Top 榜）
     */
    fun getDailyScreenTimeRange(
        startTime: Long,
        endTime: Long,
        appLimitPerDay: Int = 20
    ): List<Map<String, Any>> {
        val manager = usageStatsManager ?: return emptyList()
        val statsList = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startTime,
            endTime
        ) ?: return emptyList()

        val homePackages = getLauncherPackages()

        // 预生成区间内所有自然日，保证没用机的那天也有柱子
        val dayKeys = mutableListOf<Long>()
        val dayCal = Calendar.getInstance().apply {
            timeInMillis = startTime
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        while (dayCal.timeInMillis <= endTime) {
            dayKeys.add(dayCal.timeInMillis)
            dayCal.add(Calendar.DAY_OF_YEAR, 1)
        }
        if (dayKeys.isEmpty()) {
            return emptyList()
        }
        val dayIndex = dayKeys.withIndex().associate { (index, key) -> key to index }

        // dayIndex -> (pkg -> ms)
        val dailyApps = Array(dayKeys.size) { mutableMapOf<String, Long>() }

        for (stats in statsList) {
            val pkg = stats.packageName
            if (pkg.isNullOrBlank() || pkg == "android" || homePackages.contains(pkg)) {
                continue
            }
            val time = stats.totalTimeInForeground
            if (time <= 0) {
                continue
            }
            // UsageStats 的 bucket 边界只能靠 firstTimeStamp / lastTimeStamp 定位
            // （没有 beginTime/endTime 这两个 getter），二者即该聚合区间的起止
            val begin = stats.firstTimeStamp
            val end = if (stats.lastTimeStamp > begin) stats.lastTimeStamp else begin
            if (end < startTime || begin > endTime) {
                continue
            }
            // 跨自然日的 bucket 按与各日的重叠时长比例拆分，
            // 否则整段会被记到 bucket 起始那天，导致相邻两天一高一低
            val span = (end - begin).coerceAtLeast(1L)
            for ((dayStart, overlapMs) in splitByDay(begin, end)) {
                val idx = dayIndex[dayStart] ?: continue
                val share = if (span == 1L) time else time * overlapMs / span
                if (share > 0) {
                    dailyApps[idx][pkg] = (dailyApps[idx][pkg] ?: 0L) + share
                }
            }
        }

        val todayStart = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        val result = mutableListOf<Map<String, Any>>()
        for ((idx, dayStart) in dayKeys.withIndex()) {
            val apps = dailyApps[idx]
            var total = 0L
            for ((_, ms) in apps) {
                total += ms
            }
            val topApps = apps.filter { it.value >= 10_000L }
                .toList()
                .sortedByDescending { it.second }
                .take(appLimitPerDay)
                .map { mapOf("pkg" to it.first, "name" to getAppLabel(it.first), "ms" to it.second) }

            val cal = Calendar.getInstance().apply { timeInMillis = dayStart }
            result.add(
                mapOf(
                    "date" to dayStart,
                    "totalTime" to total,
                    "dayOfWeek" to cal.get(Calendar.DAY_OF_WEEK),
                    "isToday" to (dayStart == todayStart),
                    "topApps" to topApps
                )
            )
        }
        return result
    }

    /**
     * 把 [from, to] 按自然日切分为 (当日 00:00, 该日重叠毫秒) 列表。
     * 用 Calendar 推进而非 24 小时定值，避开夏令时导致的偏差。
     */
    private fun splitByDay(from: Long, to: Long): List<Pair<Long, Long>> {
        val parts = mutableListOf<Pair<Long, Long>>()
        if (to <= from) {
            val cal = Calendar.getInstance().apply {
                timeInMillis = from
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            return listOf(cal.timeInMillis to 1L)
        }
        val cal = Calendar.getInstance().apply {
            timeInMillis = from
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        while (cal.timeInMillis < to) {
            val dayStart = cal.timeInMillis
            cal.add(Calendar.DAY_OF_YEAR, 1)
            val dayEnd = cal.timeInMillis
            val overlapStart = maxOf(from, dayStart)
            val overlapEnd = minOf(to, dayEnd)
            if (overlapEnd > overlapStart) {
                parts.add(dayStart to (overlapEnd - overlapStart))
            }
        }
        return parts
    }

    /**
     * 计算特定时间段内的屏幕总时长（毫秒）
     */
    fun calculateTotalScreenTime(startTime: Long, endTime: Long): Long {
        val manager = usageStatsManager ?: return 0L
        val statsList = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startTime,
            endTime
        ) ?: return 0L

        val homePackages = getLauncherPackages()
        var total = 0L
        val maxAppTimeMap = mutableMapOf<String, Long>()

        for (stats in statsList) {
            val pkg = stats.packageName ?: continue
            if (pkg == "android" || homePackages.contains(pkg)) continue
            val time = stats.totalTimeInForeground
            if (time > 0) {
                // 部分系统单日会有多段区间拆分，按包名累加
                maxAppTimeMap[pkg] = (maxAppTimeMap[pkg] ?: 0L) + time
            }
        }
        for ((_, time) in maxAppTimeMap) {
            total += time
        }
        return total
    }

    /**
     * 获取桌面 Launcher 的包名列表
     */
    private fun getLauncherPackages(): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
        }
        val resolveInfoList = packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        return resolveInfoList.mapNotNull { it.activityInfo?.packageName }.toSet()
    }

    /**
     * 根据包名获取应用可读名称
     *
     * 带缓存：区间查询会对多天的同一批包名取标签，PackageManager 调用不便宜。
     */
    private fun getAppLabel(packageName: String): String {
        labelCache[packageName]?.let { return it }
        val label = try {
            val appInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getApplicationInfo(packageName, PackageManager.ApplicationInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getApplicationInfo(packageName, 0)
            }
            packageManager.getApplicationLabel(appInfo).toString()
        } catch (_: Exception) {
            packageName.substringAfterLast('.')
        }
        labelCache[packageName] = label
        return label
    }

    /**
     * 根据包名获取应用图标并转为 PNG 字节流（带内存缓存与尺寸压缩）
     */
    private fun getAppIconBytes(packageName: String): ByteArray? {
        if (iconCache.containsKey(packageName)) {
            return iconCache[packageName]
        }
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 85, stream)
            val bytes = stream.toByteArray()
            iconCache[packageName] = bytes
            bytes
        } catch (_: Exception) {
            iconCache[packageName] = null
            null
        }
    }

    /**
     * Drawable 转 Bitmap (适应 AdaptiveIconDrawable 与常规 Drawable，控制在 96x96 px 以内节省开销)
     */
    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        val targetSize = 96
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val orig = drawable.bitmap
            if (orig.width <= targetSize && orig.height <= targetSize) {
                return orig
            }
            return Bitmap.createScaledBitmap(orig, targetSize, targetSize, true)
        }

        val bitmap = Bitmap.createBitmap(targetSize, targetSize, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
