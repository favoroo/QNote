package com.appone.qnote_flutter

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Process
import android.provider.Settings
import java.io.ByteArrayOutputStream
import java.util.Calendar

/**
 * 屏幕使用情况统计。
 *
 * 主路径用 [UsageStatsManager.queryEvents] 的状态事件精确计算，而不是
 * [UsageStatsManager.queryUsageStats]：
 * - queryUsageStats 返回的是「统计桶」的累计值，桶边界既不是本地 0 点（是滚动 24 小时
 *   窗口，还会随每天首次事件漂移），也不会按查询区间裁剪。查「今天 00:00~现在」会命中
 *   从昨晚 21:33 开始的桶，把昨晚的使用也算成今天（实测差出 1 小时 15 分）。
 * - queryEvents 每个事件都带毫秒时间戳，可以精确裁剪到查询区间和屏幕亮屏时段。
 *
 * 极少数 ROM 会限制 queryEvents（读不到事件），此时回退到统计桶估算（见文件末尾）。
 */
class UsageStatsHelper(private val context: Context) {

    private companion object {
        /** 上榜门槛：低于 10 秒的应用不进应用榜 */
        const val MIN_APP_USAGE_MS = 10_000L

        /**
         * 事件预取回看窗口：查询区间前多取这段事件。
         *
         * 区间开始时已经处于 resumed 的活动，它的 ACTIVITY_RESUMED 事件落在区间之前，
         * 不多取就会漏算它在区间内的前台时长；还原查询起点时的屏幕亮灭状态也需要这段上下文。
         */
        const val EVENT_LOOKBACK_MS = 24L * 60 * 60 * 1000
    }

    private val usageStatsManager =
        context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
    private val packageManager: PackageManager = context.packageManager
    private val iconCache = mutableMapOf<String, ByteArray?>()
    private val labelCache = mutableMapOf<String, String>()

    /**
     * 事件流是否可用。第一次成功读到活动事件后置为 true；此后查询结果为空的区间一律按
     * 「确实没有使用」处理，不再退回统计桶 —— 否则回看几天前、事件已过保留期的日期时，
     * 统计桶会把两个相邻桶都算进来（最长 48 小时），又出现虚高。
     */
    @Volatile
    private var eventsSupported = false

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
     * 获取 [startTime, endTime] 的屏幕总时长与各应用使用明细（一次事件查询同时得到两者）。
     *
     * 返回的 map：
     * - `totalTime`：有桌面入口的用户应用前台时长之和（毫秒）
     * - `appList`：按时长倒序、过滤 10 秒门槛的前 N 个应用
     *
     * @param startTime 区间起点毫秒时间戳
     * @param endTime 区间终点毫秒时间戳
     * @param limit 最多返回前 N 个应用
     * @param includeIcons 是否取应用图标字节（不需要时设 false 可省掉一轮 PackageManager IPC）
     */
    fun getUsageSnapshot(
        startTime: Long,
        endTime: Long,
        limit: Int = 30,
        includeIcons: Boolean = true
    ): Map<String, Any?> {
        val intervals = collectUserAppIntervals(startTime, endTime)
            ?: return legacyUsageSnapshot(startTime, endTime, limit, includeIcons)

        val totals = HashMap<String, Long>(intervals.size)
        val lastUsedMap = HashMap<String, Long>(intervals.size)
        for ((pkg, spans) in intervals) {
            var sum = 0L
            var last = 0L
            for (span in spans) {
                sum += span[1] - span[0]
                if (span[1] > last) {
                    last = span[1]
                }
            }
            totals[pkg] = sum
            lastUsedMap[pkg] = last
        }

        val appList = totals.entries
            .filter { it.value >= MIN_APP_USAGE_MS }
            .sortedByDescending { it.value }
            .take(limit)
            .map { (pkg, ms) ->
                mapOf(
                    "packageName" to pkg,
                    "appName" to getAppLabel(pkg),
                    "totalTimeInForeground" to ms,
                    "lastTimeUsed" to (lastUsedMap[pkg] ?: 0L),
                    "icon" to if (includeIcons) getAppIconBytes(pkg) else null
                )
            }

        var total = 0L
        for (value in totals.values) {
            total += value
        }
        return mapOf("totalTime" to total, "appList" to appList)
    }

    /**
     * 计算 [startTime, endTime] 内的屏幕总时长（毫秒）。
     *
     * 口径与 [getUsageSnapshot] 的 `totalTime` 一致：只统计有桌面入口的用户应用，
     * 排除桌面、SystemUI、输入法等系统组件；每段区间都已裁剪到屏幕亮屏时段。
     */
    fun calculateTotalScreenTime(startTime: Long, endTime: Long): Long {
        val intervals = collectUserAppIntervals(startTime, endTime)
            ?: return legacyTotalScreenTime(startTime, endTime)
        var total = 0L
        for (spans in intervals.values) {
            for (span in spans) {
                total += span[1] - span[0]
            }
        }
        return total
    }

    /**
     * 获取区间内逐日的屏幕总时长与各应用明细（本地自然日分桶）。
     *
     * 事件流自带毫秒时间戳，跨零点的前台区间按与各自然日的真实重叠时长拆分，
     * 不会像统计桶那样把整段记到某一天。每日总量不过滤 10 秒门槛（与
     * [calculateTotalScreenTime] 口径一致，柱状图与大数字才对得上）；
     * 应用明细则沿用 10 秒门槛与倒序截断。
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
        val days = enumerateDays(startTime, endTime)
        if (days.isEmpty()) {
            return emptyList()
        }

        val intervals = collectUserAppIntervals(startTime, endTime)
            ?: return legacyDailyScreenTimeRange(startTime, endTime, appLimitPerDay)

        // dayIndex -> (pkg -> ms)
        val perDayApps = Array(days.size) { HashMap<String, Long>() }
        for ((pkg, spans) in intervals) {
            for (span in spans) {
                for (i in days.indices) {
                    val dayEnd = if (i + 1 < days.size) days[i + 1] else Long.MAX_VALUE
                    val overlapStart = maxOf(span[0], days[i])
                    val overlapEnd = minOf(span[1], dayEnd)
                    if (overlapEnd > overlapStart) {
                        val bucket = perDayApps[i]
                        bucket[pkg] = (bucket[pkg] ?: 0L) + (overlapEnd - overlapStart)
                    }
                }
            }
        }

        val todayStart = startOfDay(System.currentTimeMillis())
        return days.mapIndexed { index, dayStart ->
            val apps = perDayApps[index]
            var total = 0L
            for (value in apps.values) {
                total += value
            }
            val topApps = apps.entries
                .filter { it.value >= MIN_APP_USAGE_MS }
                .sortedByDescending { it.value }
                .take(appLimitPerDay)
                .map { mapOf("pkg" to it.key, "name" to getAppLabel(it.key), "ms" to it.value) }

            mapOf(
                "date" to dayStart,
                "totalTime" to total,
                "dayOfWeek" to dayOfWeek(dayStart),
                "isToday" to (dayStart == todayStart),
                "topApps" to topApps
            )
        }
    }

    /**
     * 获取最近 7 天（含今天）的每日屏幕总时长，供周柱状图展示。
     *
     * 只要每日总量，appLimitPerDay 传 0 可以免掉取应用标签的开销；返回项里的
     * `topApps` 会是空列表，调用方按需忽略。
     */
    fun getWeeklyScreenTime(): List<Map<String, Any>> {
        val todayStart = startOfDay(System.currentTimeMillis())
        val firstDay = Calendar.getInstance().apply {
            timeInMillis = todayStart
            add(Calendar.DAY_OF_YEAR, -6)
        }.timeInMillis
        return getDailyScreenTimeRange(firstDay, System.currentTimeMillis(), appLimitPerDay = 0)
    }

    /**
     * 按包名批量获取应用图标（PNG 字节），供「只有包名」的场景补齐图标，
     * 例如区间应用榜来自逐日快照，快照里不存图标。
     *
     * 只返回成功取到图标的包名；未安装或取不到图标的包名不出现在结果中，
     * 由 Flutter 侧走首字母色块兜底。结果复用 [getAppIconBytes] 的内存缓存。
     */
    fun getAppIcons(packageNames: List<String>): Map<String, ByteArray> {
        val icons = mutableMapOf<String, ByteArray>()
        for (pkg in packageNames.filter { it.isNotBlank() }.distinct()) {
            getAppIconBytes(pkg)?.let { icons[pkg] = it }
        }
        return icons
    }

    // ------------------------------------------------------------------
    // 事件流聚合
    // ------------------------------------------------------------------

    /**
     * 解析事件流，得到每个**用户应用**在 [startTime, endTime] 内的前台区间。
     *
     * 返回 null 表示这段区间一条事件都读不到（事件流不可用），调用方应回退到统计桶估算；
     * 返回空 Map 表示事件正常但确实没有可统计的使用。
     */
    private fun collectUserAppIntervals(startTime: Long, endTime: Long): Map<String, List<LongArray>>? {
        val all = collectForegroundIntervals(startTime, endTime) ?: return null
        if (all.isEmpty()) {
            return emptyMap()
        }
        val homePackages = getLauncherPackages()
        val launchablePackages = getLaunchablePackages()
        return all.filterKeys { isUserAppUsage(it, homePackages, launchablePackages) }
    }

    /**
     * 解析 [startTime, endTime] 内的事件，得到「包名 -> 前台区间（毫秒）」。
     *
     * 区间做了两层裁剪：先并集化同一个包的重叠区间（多窗口、Activity 切换过渡不重复计时），
     * 再裁到查询区间与屏幕亮屏时段（灭屏期间残留的 resumed 状态不算使用）。
     * 返回 null 表示区间内没有任何活动事件，事件流可能被 ROM 限制。
     */
    private fun collectForegroundIntervals(startTime: Long, endTime: Long): Map<String, List<LongArray>>? {
        val manager = usageStatsManager ?: return null
        if (endTime <= startTime) {
            return emptyMap()
        }

        val queryFrom = startTime - EVENT_LOOKBACK_MS
        val events = manager.queryEvents(queryFrom, endTime) ?: return null
        val event = UsageEvents.Event()

        // instanceKey -> 最近一次 resume 时间 / 所属包名
        val openSince = HashMap<String, Long>()
        val openPackage = HashMap<String, String>()
        val rawByPackage = HashMap<String, MutableList<LongArray>>()
        // 亮屏时段（毫秒区间）
        val screenSegments = mutableListOf<LongArray>()
        var screenOn = true
        var screenFrom = queryFrom
        var eventCount = 0
        var activityEventCount = 0

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            eventCount++
            val ts = event.timeStamp
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    activityEventCount++
                    val key = instanceKey(event)
                    // 同一实例重复收到 resumed（未先 pause）时保留最早的时间起点
                    if (!openSince.containsKey(key)) {
                        openSince[key] = ts
                        openPackage[key] = event.packageName
                    }
                }

                UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> {
                    activityEventCount++
                    val key = instanceKey(event)
                    val since = openSince.remove(key)
                    openPackage.remove(key)
                    if (since != null && ts > since) {
                        rawByPackage.getOrPut(event.packageName) { mutableListOf() }
                            .add(longArrayOf(since, ts))
                    }
                }

                UsageEvents.Event.SCREEN_INTERACTIVE -> {
                    if (!screenOn) {
                        screenOn = true
                        screenFrom = ts
                    }
                }

                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    if (screenOn) {
                        screenOn = false
                        if (ts > screenFrom) {
                            screenSegments.add(longArrayOf(screenFrom, ts))
                        }
                    }
                }

                UsageEvents.Event.DEVICE_SHUTDOWN -> {
                    // 关机不会补发 pause，把仍然打开的活动在关机点收尾，避免一直计到下次开机
                    for ((key, since) in openSince) {
                        val pkg = openPackage[key] ?: continue
                        if (ts > since) {
                            rawByPackage.getOrPut(pkg) { mutableListOf() }.add(longArrayOf(since, ts))
                        }
                    }
                    openSince.clear()
                    openPackage.clear()
                }
            }
        }

        if (eventCount == 0 || activityEventCount == 0) {
            // 已经有成功读到的记录，说明事件流可用，这里的空结果就是「这段区间没有使用」
            return if (eventsSupported) emptyMap() else null
        }
        eventsSupported = true

        // 查询终点仍在前台的活动：计到查询终点
        for ((key, since) in openSince) {
            val pkg = openPackage[key] ?: continue
            if (endTime > since) {
                rawByPackage.getOrPut(pkg) { mutableListOf() }.add(longArrayOf(since, endTime))
            }
        }
        // 收尾时仍亮屏：补上最后一段亮屏区间
        if (screenOn && endTime > screenFrom) {
            screenSegments.add(longArrayOf(screenFrom, endTime))
        }

        val result = HashMap<String, List<LongArray>>()
        for ((pkg, spans) in rawByPackage) {
            val clipped = mutableListOf<LongArray>()
            for (span in mergeIntervals(spans)) {
                val start = maxOf(span[0], startTime)
                val end = minOf(span[1], endTime)
                if (end <= start) {
                    continue
                }
                for (segment in screenSegments) {
                    val overlapStart = maxOf(start, segment[0])
                    val overlapEnd = minOf(end, segment[1])
                    if (overlapEnd > overlapStart) {
                        clipped.add(longArrayOf(overlapStart, overlapEnd))
                    }
                }
            }
            val merged = mergeIntervals(clipped)
            if (merged.isNotEmpty()) {
                result[pkg] = merged
            }
        }
        return result
    }

    /**
     * 活动的配对标识：包名 + Activity 类名。
     *
     * 同一个 Activity 类不可能同时有两个实例处于 resumed，所以类名足以区分配对；
     * 用不了 [UsageEvents.Event.getInstanceId]（非公开 API）。
     */
    private fun instanceKey(event: UsageEvents.Event): String {
        return "${event.packageName}#${event.className ?: ""}"
    }

    /** 合并重叠/乱序的区间，返回按开始时间升序、互不重叠的区间列表 */
    private fun mergeIntervals(spans: List<LongArray>): List<LongArray> {
        if (spans.size <= 1) {
            return spans
        }
        val sorted = spans.sortedBy { it[0] }
        val merged = mutableListOf<LongArray>()
        var start = sorted[0][0]
        var end = sorted[0][1]
        for (i in 1 until sorted.size) {
            val span = sorted[i]
            if (span[0] <= end) {
                if (span[1] > end) {
                    end = span[1]
                }
            } else {
                merged.add(longArrayOf(start, end))
                start = span[0]
                end = span[1]
            }
        }
        merged.add(longArrayOf(start, end))
        return merged
    }

    /** 本地时间的当日 00:00:00.000 */
    private fun startOfDay(timeMs: Long): Long = Calendar.getInstance().apply {
        timeInMillis = timeMs
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    /** 星期（Calendar 口径：1=周日 … 7=周六） */
    private fun dayOfWeek(timeMs: Long): Int =
        Calendar.getInstance().apply { timeInMillis = timeMs }.get(Calendar.DAY_OF_WEEK)

    /**
     * 预生成 [startTime, endTime] 覆盖到的所有本地自然日（当日 00:00），
     * 保证没用机的那天也有柱子。用 Calendar 逐日推进而非固定 24 小时，避开夏令时偏差。
     */
    private fun enumerateDays(startTime: Long, endTime: Long): List<Long> {
        val days = mutableListOf<Long>()
        val cal = Calendar.getInstance().apply {
            timeInMillis = startTime
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        while (cal.timeInMillis <= endTime) {
            days.add(cal.timeInMillis)
            cal.add(Calendar.DAY_OF_YEAR, 1)
        }
        return days
    }

    // ------------------------------------------------------------------
    // 回退路径：极少数 ROM 会限制 queryEvents（读不到事件）时退回统计桶估算。
    // 统计桶是滚动 24 小时窗口且不按查询区间裁剪，数值会偏大，仅作兜底。
    // ------------------------------------------------------------------

    /** 统计桶聚合出的一条记录 */
    private class LegacyUsage {
        var timeMs: Long = 0
        var lastUsedMs: Long = 0
    }

    private fun legacyUsageSnapshot(
        startTime: Long,
        endTime: Long,
        limit: Int,
        includeIcons: Boolean
    ): Map<String, Any?> {
        val aggregated = legacyAggregateByPackage(startTime, endTime)
        val appList = aggregated.entries
            .filter { it.value.timeMs >= MIN_APP_USAGE_MS }
            .sortedByDescending { it.value.timeMs }
            .take(limit)
            .map {
                mapOf(
                    "packageName" to it.key,
                    "appName" to getAppLabel(it.key),
                    "totalTimeInForeground" to it.value.timeMs,
                    "lastTimeUsed" to it.value.lastUsedMs,
                    "icon" to if (includeIcons) getAppIconBytes(it.key) else null
                )
            }
        var total = 0L
        for (value in aggregated.values) {
            total += value.timeMs
        }
        return mapOf("totalTime" to total, "appList" to appList)
    }

    private fun legacyTotalScreenTime(startTime: Long, endTime: Long): Long {
        var total = 0L
        for (value in legacyAggregateByPackage(startTime, endTime).values) {
            total += value.timeMs
        }
        return total
    }

    /** 统计桶聚合：包名 -> (前台毫秒, 最近使用时间) */
    private fun legacyAggregateByPackage(startTime: Long, endTime: Long): Map<String, LegacyUsage> {
        val manager = usageStatsManager ?: return emptyMap()
        val statsList = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startTime,
            endTime
        ) ?: return emptyMap()

        val homePackages = getLauncherPackages()
        val launchablePackages = getLaunchablePackages()
        val aggregated = HashMap<String, LegacyUsage>()
        for (stats in statsList) {
            val pkg = stats.packageName
            if (!isUserAppUsage(pkg, homePackages, launchablePackages)) {
                continue
            }
            val time = stats.totalTimeInForeground
            if (time <= 0) {
                continue
            }
            val item = aggregated.getOrPut(pkg) { LegacyUsage() }
            // 部分系统单日会有多段区间拆分，按包名累加
            item.timeMs += time
            if (stats.lastTimeUsed > item.lastUsedMs) {
                item.lastUsedMs = stats.lastTimeUsed
            }
        }
        return aggregated
    }

    private fun legacyDailyScreenTimeRange(
        startTime: Long,
        endTime: Long,
        appLimitPerDay: Int
    ): List<Map<String, Any>> {
        val manager = usageStatsManager ?: return emptyList()
        val statsList = manager.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            startTime,
            endTime
        ) ?: return emptyList()

        val homePackages = getLauncherPackages()
        val launchablePackages = getLaunchablePackages()
        val dayKeys = enumerateDays(startTime, endTime)
        if (dayKeys.isEmpty()) {
            return emptyList()
        }
        val dayIndex = dayKeys.withIndex().associate { (index, key) -> key to index }

        // dayIndex -> (pkg -> ms)
        val dailyApps = Array(dayKeys.size) { HashMap<String, Long>() }
        for (stats in statsList) {
            val pkg = stats.packageName
            if (!isUserAppUsage(pkg, homePackages, launchablePackages)) {
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

        val todayStart = startOfDay(System.currentTimeMillis())
        return dayKeys.mapIndexed { idx, dayStart ->
            val apps = dailyApps[idx]
            var total = 0L
            for (value in apps.values) {
                total += value
            }
            val topApps = apps.entries
                .filter { it.value >= MIN_APP_USAGE_MS }
                .sortedByDescending { it.value }
                .take(appLimitPerDay)
                .map { mapOf("pkg" to it.key, "name" to getAppLabel(it.key), "ms" to it.value) }

            mapOf(
                "date" to dayStart,
                "totalTime" to total,
                "dayOfWeek" to dayOfWeek(dayStart),
                "isToday" to (dayStart == todayStart),
                "topApps" to topApps
            )
        }
    }

    /**
     * 把 [from, to] 按自然日切分为 (当日 00:00, 该日重叠毫秒) 列表。
     * 用 Calendar 推进而非 24 小时定值，避开夏令时导致的偏差。
     */
    private fun splitByDay(from: Long, to: Long): List<Pair<Long, Long>> {
        val parts = mutableListOf<Pair<Long, Long>>()
        if (to <= from) {
            return listOf(startOfDay(from) to 1L)
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

    // ------------------------------------------------------------------
    // 包信息工具
    // ------------------------------------------------------------------

    /**
     * 判断某个包的使用时长是否计入屏幕使用时间：
     * 排除空包名、系统进程（android）、桌面 Launcher，以及没有桌面入口的包
     * （SystemUI、输入法等，Android 11+ 需配合 Manifest 的 queries 声明才能查到）。
     */
    private fun isUserAppUsage(pkg: String?, homePackages: Set<String>, launchablePackages: Set<String>): Boolean {
        if (pkg.isNullOrBlank() || pkg == "android") return false
        if (homePackages.contains(pkg)) return false
        return launchablePackages.contains(pkg)
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
     * 获取有桌面入口（可从桌面启动）的应用包名集合
     *
     * SystemUI、输入法等系统组件没有 launcher 入口，把它们的前台时长计入屏幕使用
     * 会严重虚高，故只统计可从桌面启动的用户应用。与 [getLauncherPackages] 一样
     * 每次查询现取一次，避免应用安装/卸载后读到过期结果。
     */
    private fun getLaunchablePackages(): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolveInfoList = packageManager.queryIntentActivities(intent, 0)
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
     *
     * 缓存会被主线程的实时查询与批量取图的后台线程并发读写，故缓存读写统一加锁；
     * PackageManager 取图与 PNG 压缩放在锁外，避免后台取图时把 UI 线程一起挡住。
     */
    private fun getAppIconBytes(packageName: String): ByteArray? {
        synchronized(iconCache) {
            if (iconCache.containsKey(packageName)) {
                return iconCache[packageName]
            }
        }
        val bytes = try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 85, stream)
            stream.toByteArray()
        } catch (_: Exception) {
            null
        }
        synchronized(iconCache) {
            iconCache[packageName] = bytes
        }
        return bytes
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
