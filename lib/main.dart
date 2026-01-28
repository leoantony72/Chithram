import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'providers/photo_provider.dart';
import 'ui/scaffold_with_navbar.dart';
import 'ui/pages/all_photos_page.dart';
import 'ui/pages/people_page.dart';
import 'ui/pages/albums_page.dart';
import 'ui/pages/asset_viewer_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Increase ImageCache to 500MB to allow "Screen Nail" pre-caching 
  // without constant eviction during swiping.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 500 * 1024 * 1024;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PhotoProvider()),
      ],
      child: const NintaApp(),
    ),
  );
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _sectionNavigatorKey = GlobalKey<NavigatorState>();

final GoRouter _router = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (BuildContext context, GoRouterState state, StatefulNavigationShell navigationShell) {
        return ScaffoldWithNavBar(navigationShell: navigationShell);
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (BuildContext context, GoRouterState state) => const AllPhotosPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/people',
              builder: (BuildContext context, GoRouterState state) => const PeoplePage(),
            ),
          ],
        ),
         StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: '/albums',
              builder: (BuildContext context, GoRouterState state) => const AlbumsPage(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/viewer',
      builder: (context, state) {
        final asset = state.extra as AssetEntity; 
        return AssetViewerPage(asset: asset);
      },
    ),
  ],
);

class NintaApp extends StatelessWidget {
  const NintaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Ninta Photos',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.blueAccent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.blueAccent,
          unselectedItemColor: Colors.grey,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Colors.blueAccent,
          secondary: Colors.white,
          background: Colors.black,
        ),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
