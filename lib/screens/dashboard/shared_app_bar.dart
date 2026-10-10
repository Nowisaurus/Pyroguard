import 'package:flutter/material.dart';
import '../../theme.dart';
import 'main_shell.dart' show kDesktopBreakpoint, pyroShellScaffoldKey;

class PyroAppBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback? onOpenMenu;
  final bool systemOnline;
  final String title;
  final String? subtitle;
  final List<Widget> extraActions;

  const PyroAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.extraActions = const [],
    this.onOpenMenu,
    this.systemOnline = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(68);

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 68,
      automaticallyImplyLeading: false,
      titleSpacing: isDesktop ? 22 : 12,
      title: Row(
        children: [
          const PyroGuardLogo(),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isDesktop ? 18 : 15.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary(context),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.textSecondary(context),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        ...extraActions,
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: systemOnline ? AppColors.green : AppColors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                systemOnline ? (isDesktop ? 'SYSTEM ONLINE' : 'ONLINE') : (isDesktop ? 'CONNECTION CHECK' : 'CHECK'),
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  color: systemOnline ? AppTheme.safeForeground(context) : AppColors.amber,
                ),
              ),
            ],
          ),
        ),
        if (!isDesktop)
          IconButton(
            tooltip: 'Open navigation',
            icon: Icon(Icons.menu, color: AppTheme.textPrimary(context), size: 24),
            onPressed: onOpenMenu ?? () => pyroShellScaffoldKey.currentState?.openEndDrawer(),
          )
        else
          const SizedBox(width: 14),
      ],
    );
  }
}
