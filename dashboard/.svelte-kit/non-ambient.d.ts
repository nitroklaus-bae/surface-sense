
// this file is generated — do not edit it


declare module "svelte/elements" {
	export interface HTMLAttributes<T> {
		'data-sveltekit-keepfocus'?: true | '' | 'off' | undefined | null;
		'data-sveltekit-noscroll'?: true | '' | 'off' | undefined | null;
		'data-sveltekit-preload-code'?:
			| true
			| ''
			| 'eager'
			| 'viewport'
			| 'hover'
			| 'tap'
			| 'off'
			| undefined
			| null;
		'data-sveltekit-preload-data'?: true | '' | 'hover' | 'tap' | 'off' | undefined | null;
		'data-sveltekit-reload'?: true | '' | 'off' | undefined | null;
		'data-sveltekit-replacestate'?: true | '' | 'off' | undefined | null;
	}
}

export {};


declare module "$app/types" {
	type MatcherParam<M> = M extends (param : string) => param is (infer U extends string) ? U : string;

	export interface AppTypes {
		RouteId(): "/" | "/api" | "/api/intervals" | "/api/intervals/fit" | "/api/osm" | "/api/osm/overpass" | "/api/strava" | "/api/strava/activities" | "/api/strava/auth" | "/api/strava/callback" | "/api/strava/streams" | "/crr" | "/login";
		RouteParams(): {
			
		};
		LayoutParams(): {
			"/": Record<string, never>;
			"/api": Record<string, never>;
			"/api/intervals": Record<string, never>;
			"/api/intervals/fit": Record<string, never>;
			"/api/osm": Record<string, never>;
			"/api/osm/overpass": Record<string, never>;
			"/api/strava": Record<string, never>;
			"/api/strava/activities": Record<string, never>;
			"/api/strava/auth": Record<string, never>;
			"/api/strava/callback": Record<string, never>;
			"/api/strava/streams": Record<string, never>;
			"/crr": Record<string, never>;
			"/login": Record<string, never>
		};
		Pathname(): "/" | "/api/intervals" | "/api/intervals/fit" | "/api/osm/overpass" | "/api/strava/activities" | "/api/strava/auth" | "/api/strava/callback" | "/api/strava/streams" | "/crr" | "/login";
		ResolvedPathname(): `${"" | `/${string}`}${ReturnType<AppTypes['Pathname']>}`;
		Asset(): "/raw/index.html" | string & {};
	}
}