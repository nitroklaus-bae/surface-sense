<script>
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { page } from '$app/stores';
  import { supabase, signOut, isAdmin } from '$lib/supabase.js';

  let user = null;
  let admin = false;
  let loading = true;

  onMount(async () => {
    const { data: { session } } = await supabase.auth.getSession();
    user = session?.user ?? null;
    if (user) admin = await isAdmin();
    loading = false;

    if (!user && $page.url.pathname !== '/login') {
      goto('/login');
    }

    supabase.auth.onAuthStateChange(async (_event, session) => {
      user = session?.user ?? null;
      admin = user ? await isAdmin() : false;
      if (!user) goto('/login');
    });
  });

  async function handleSignOut() {
    await signOut();
    goto('/login');
  }
</script>

{#if loading}
  <div class="loading">
    <div class="spinner"></div>
  </div>
{:else if !user && $page.url.pathname !== '/login'}
  <!-- wird von onMount zu /login weitergeleitet -->
{:else}
  {#if user}
    <nav>
      <div class="nav-brand">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M12 2L2 7l10 5 10-5-10-5z"/>
          <path d="M2 17l10 5 10-5M2 12l10 5 10-5"/>
        </svg>
        SurfaceSense
      </div>
      <div class="nav-right">
        {#if admin}
          <span class="badge-admin">ADMIN</span>
        {/if}
        <span class="nav-email">{user.email}</span>
        <button class="btn-logout" on:click={handleSignOut}>Abmelden</button>
      </div>
    </nav>
  {/if}
  <main>
    <slot />
  </main>
{/if}

<style>
  :global(*, *::before, *::after) { box-sizing: border-box; margin: 0; padding: 0; }
  :global(body) {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: #0d1117;
    color: #e6edf3;
    height: 100vh;
    overflow: hidden;
  }

  .loading {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
  }
  .spinner {
    width: 32px; height: 32px;
    border: 3px solid #30363d;
    border-top-color: #2dd4bf;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  nav {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 24px;
    height: 52px;
    background: #161b22;
    border-bottom: 1px solid #30363d;
    flex-shrink: 0;
  }
  .nav-brand {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 700;
    font-size: 15px;
    color: #2dd4bf;
  }
  .nav-right {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .nav-email {
    font-size: 13px;
    color: #8b949e;
  }
  .btn-logout {
    background: none;
    border: 1px solid #30363d;
    color: #8b949e;
    padding: 4px 12px;
    border-radius: 6px;
    font-size: 13px;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s;
  }
  .btn-logout:hover { border-color: #8b949e; color: #e6edf3; }

  .badge-admin {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 1px;
    background: #2dd4bf22;
    color: #2dd4bf;
    border: 1px solid #2dd4bf55;
    border-radius: 4px;
    padding: 2px 7px;
  }

  main {
    height: calc(100vh - 52px);
    overflow: hidden;
  }
</style>
