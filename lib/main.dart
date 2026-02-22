import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'providers/photo_provider.dart';
import 'providers/selection_provider.dart';
import 'ui/scaffold_with_navbar.dart';
import 'ui/pages/all_photos_page.dart';
import 'ui/pages/people_page.dart';
import 'ui/pages/albums_page.dart';
import 'ui/pages/asset_viewer_page.dart';
import 'ui/pages/person_details_page.dart';
import 'ui/pages/album_details_page.dart';
import 'ui/pages/cloud_album_details_page.dart';
import 'ui/pages/map_page.dart';
import 'ui/pages/settings_page.dart';
import 'screens/auth_screen.dart';
import 'models/gallery_item.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Increase ImageCache to 500MB to allow "Screen Nail" pre-caching 
  // without constant eviction during swiping.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 500 * 1024 * 1024;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PhotoProvider()),
        ChangeNotifierProvider(create: (_) => SelectionProvider()),
      ],
      child: const NintaApp(),
    ),
  );
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _sectionNavigatorKey = GlobalKey<NavigatorState>();

final GoRouter _router = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/auth',
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
        final extra = state.extra;
        if (extra is GalleryItem) {
          return AssetViewerPage(item: extra);
        } else if (extra is AssetEntity) {
          // Fallback for existing calls
          return AssetViewerPage(item: GalleryItem.local(extra));
        }
        throw Exception("Invalid argument for /viewer: $extra");
      },
    ),


    GoRoute(
      path: '/person_details',
      builder: (context, state) {
        final Map<String, dynamic> args = state.extra as Map<String, dynamic>;
        return PersonDetailsPage(
          personName: args['name'] as String,
          personId: args['id'] as int,
        );
      },
    ),


    GoRoute(
      path: '/album_details',
      builder: (context, state) {
        final AssetPathEntity album = state.extra as AssetPathEntity;
        return AlbumDetailsPage(album: album);
      },
    ),
    GoRoute(
      path: '/albums/:albumName',
      builder: (context, state) {
        final albumName = state.pathParameters['albumName']!;
        return CloudAlbumDetailsPage(albumName: albumName);
      },
    ),
    GoRoute(
      path: '/map',
      builder: (context, state) => const MapPage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
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
