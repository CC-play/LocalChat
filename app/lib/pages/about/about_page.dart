import 'package:flutter/material.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/pages/changelog_page.dart';
import 'package:localchat_app/pages/debug/debug_page.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/provider/version_provider.dart';
import 'package:localchat_app/widget/local_chat_logo.dart';
import 'package:localchat_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:url_launcher/url_launcher.dart';

/// Upstream project this app is built on.
const String _localsendRepoUrl = 'https://github.com/localsend/localsend';

/// Licence inherited from LocalSend.
const String _licenseUrl = 'https://www.apache.org/licenses/LICENSE-2.0';

class AboutPage extends StatelessWidget {
  const AboutPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final advanced = context.ref.watch(settingsProvider.select((s) => s.advancedSettings));
    final version = context.ref.watch(versionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.aboutPage.title),
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        children: [
          const SizedBox(height: 24),
          const LocalChatLogo(withText: true),
          const SizedBox(height: 10),
          version.maybeWhen(
            data: (version) => Text(
              t.aboutPage.version(version: version.combinedString),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            orElse: () => const SizedBox(height: 16),
          ),
          const SizedBox(height: 28),
          Text(
            t.aboutPage.description.join('\n\n'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: theme.inputDecorationTheme.fillColor,
              borderRadius: theme.inputDecorationTheme.borderRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.aboutPage.forkNotice,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.6, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  t.aboutPage.upstreamCredit(year: '${DateTime.now().year}'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              // 15 - 10: the link rows' highlight bleeds 10px outwards so their
              // labels stay aligned with the rest of the page.
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
              child: Column(
                children: [
                  _LinkEntry(
                    label: t.aboutPage.localsendRepo,
                    onTap: () async {
                      await launchUrl(Uri.parse(_localsendRepoUrl), mode: LaunchMode.externalApplication);
                    },
                  ),
                  _LinkEntry(
                    label: t.aboutPage.license,
                    onTap: () async {
                      await launchUrl(Uri.parse(_licenseUrl), mode: LaunchMode.externalApplication);
                    },
                  ),
                  _LinkEntry(
                    label: t.aboutPage.licenseNotices,
                    onTap: () async {
                      await context.push(() => const LicensePage());
                    },
                  ),
                  _LinkEntry(
                    label: t.changelogPage.title,
                    onTap: () async {
                      await context.push(() => const ChangelogPage());
                    },
                  ),
                  if (advanced)
                    _LinkEntry(
                      label: t.aboutPage.debugging,
                      onTap: () async {
                        await context.push(() => const DebugPage());
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 50),
        ],
      ),
    );
  }
}

/// A tappable row that opens another page: label on the left, chevron on the right.
///
/// The highlight pill bleeds 10px outwards (the enclosing [Card] is inset by
/// 15 - 10 = 5), so the label stays aligned with the rest of the page while the
/// highlight keeps horizontal breathing room.
class _LinkEntry extends StatelessWidget {
  final String label;
  final void Function() onTap;

  const _LinkEntry({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: theme.inputDecorationTheme.borderRadius,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, size: 22, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
