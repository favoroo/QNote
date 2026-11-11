/// 浏览器回环登录的句柄：打开 [url]，等待厂商回调到本机端口
///
/// [code] 完成时返回授权码；[cancel] 用于用户主动取消或弹层关闭。
class RaccoonLoopbackLogin {
  final String url;
  final Future<String> code;
  final void Function() cancel;

  const RaccoonLoopbackLogin({required this.url, required this.code, required this.cancel});
}
