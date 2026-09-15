import 'package:acp_agent_client/app/paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default data dir follows docs/design.md § 10 on this platform', () {
    final dir = defaultDataDir(environment: <String, String>{
      'APPDATA': r'C:\Users\测试 用户\AppData\Roaming',
      'HOME': '/home/u',
      'XDG_DATA_HOME': '/xdg',
    });
    expect(dir, endsWith(appDirName));
    expect(dir, anyOf(startsWith(r'C:\Users\测试 用户\AppData\Roaming'), startsWith('/home/u'), startsWith('/xdg')));
  });
}
