import 'package:flutter/widgets.dart';

enum AppLanguage {
  system('system', '跟随系统', null),
  simplified(
    'zh-Hans',
    '简体中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ),
  traditional(
    'zh-Hant',
    '繁體中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ),
  japanese('ja', '日本語', Locale('ja')),
  english('en', 'English', Locale('en'));

  const AppLanguage(this.code, this.name, this.locale);
  final String code, name;
  final Locale? locale;
  static AppLanguage parse(String? code) =>
      values.firstWhere((value) => value.code == code, orElse: () => system);
}
