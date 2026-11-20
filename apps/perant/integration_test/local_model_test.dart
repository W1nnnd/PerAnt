// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:perant/src/application/device_inference.dart';
import 'package:perant/src/data/gguf_models.dart';
import 'package:perant_core/perant_core.dart';

import 'local_materials_test.dart' as materials;

const queries = {
  LocalAction.search: [
    '找一找',
    '帮我查找资料',
    '我想搜索文件',
    '查询已有笔记',
    '找出包含这些字的文档',
    '查一下',
    '检索我的资料',
    '帮我搜搜',
    '在收藏里寻找',
    '看看有没有这个文件',
    '从文档中查找',
    '哪份资料提到',
    '帮忙定位原文',
    '在笔记里搜',
    '从资料库调出',
    '搜索相关材料',
    '查找现有记录',
    '找含有关键词的文件',
    '翻出以前存的资料',
    '查询文档标题',
  ],
  LocalAction.note: [
    '新建笔记，记下',
    '请帮我做个记录',
    '写成一条新笔记',
    '帮我记住这段笔记',
    '把这段话存成新笔记',
    '做个备忘',
    '添加一条笔记',
    '创建新便笺',
    '记录下来',
    '写入一份新草稿',
    '起草一条便签',
    '新增一条备忘',
    '记一笔',
    '建立一份笔记',
    '请新建文本笔记',
    '把这句存成便签',
    '留下一条笔记',
    '给我做一份新备忘',
    '新开一份笔记写下',
    '请生成一条新笔记',
  ],
  LocalAction.clarify: [
    '删除文件',
    '发给朋友',
    '运行命令',
    '覆盖已有文档',
    '把资料上传到网站',
    '打开浏览器',
    '给同事发邮件',
    '打印文件',
    '删除所有相关笔记',
    '查找后删除资料',
  ],
};
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'offline GGUF import, real CPU inference, command routing and release',
    (tester) async {
      final runtime = DeviceInference();
      const full = bool.fromEnvironment('PERANT_LOCAL_MATRIX');
      try {
        for (final spec in full ? DeviceModel.values : [DeviceModel.small]) {
          if (!await spec.installed()) {
            final source = File('/data/local/tmp/perant-007/${spec.name}');
            await spec.install(
              source.openRead(),
              stopped: () => false,
              progress: (_) {},
            );
          }
          for (final context in full ? [2048, 4096] : [2048]) {
            final clock = Stopwatch()..start();
            await runtime.load(
              LocalModelConfiguration(
                modelId: spec.id,
                modelFile: (await spec.file()).uri,
                contextTokens: context,
              ),
            );
            final loadMs = clock.elapsedMilliseconds;
            var ok = 0, attempted = 0;
            final times = <int>[];
            final failed = <String>[];
            for (final group in queries.entries) {
              for (final phrase in full ? group.value : group.value.take(2)) {
                clock.reset();
                final data = '周三项目进度${attempted + 1}';
                final proposal = await proposeLocalAction(
                  runtime,
                  '$phrase「$data」',
                  'case-$attempted',
                );
                times.add(clock.elapsedMilliseconds);
                attempted++;
                if (group.key == proposal.action &&
                    (group.key == LocalAction.clarify ||
                        proposal.argument == data)) {
                  ok++;
                } else {
                  failed.add('$phrase=${proposal.action.name}');
                }
              }
            }
            final first = times.first;
            times.sort();
            debugPrint(
              'PERANT_LOCAL ${spec.id} ctx=$context load=$loadMs first=$first correct=$ok/$attempted p50=${times[(times.length * .5).ceil() - 1]} p90=${times[(times.length * .9).ceil() - 1]} misses=$failed',
            );
            expect(ok, greaterThan(0));
            final answer = StringBuffer();
            var completed = false;
            await for (final ev in runtime.generate(
              ModelRequest(
                id: 'reply',
                taskId: 'reply',
                maxOutputTokens: 48,
                messages: [
                  ModelMessage(
                    role: ModelRole.user,
                    content: '请只用中文回答：中国的首都是哪座城市？',
                  ),
                ],
              ),
            )) {
              if (ev.type == ModelEventType.textDelta) answer.write(ev.text);
              if (ev.type == ModelEventType.completed) completed = true;
            }
            expect(completed, isTrue);
            expect(answer.toString(), contains('北京'));
            await runtime.unload();
            expect(
              (await runtime.inspect()).availability,
              RuntimeAvailability.notInstalled,
            );
          }
        }
      } finally {
        await runtime.unload();
      }
    },
    timeout: const Timeout(Duration(minutes: 60)),
  );
  if (const bool.fromEnvironment('PERANT_LOCAL_DOCUMENTS')) materials.main();
}
