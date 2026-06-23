<script>
  import { goto } from '$app/navigation';
  import { signIn, supabase } from '$lib/supabase.js';
  import { onMount } from 'svelte';

  let email = '';
  let password = '';
  let error = '';
  let loading = false;

  onMount(async () => {
    const { data: { session } } = await supabase.auth.getSession();
    if (session) goto('/');
  });

  async function handleLogin() {
    if (!email || !password) return;
    loading = true;
    error = '';
    try {
      await signIn(email, password);
      goto('/');
    } catch (e) {
      error = e.message;
    } finally {
      loading = false;
    }
  }

  function onKeydown(e) {
    if (e.key === 'Enter') handleLogin();
  }
</script>

<svelte:head><title>Login – SurfaceSense</title></svelte:head>

<div class="page">
  <div class="card">
    <div class="logo">
      <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#2dd4bf" stroke-width="1.5">
        <path d="M12 2L2 7l10 5 10-5-10-5z"/>
        <path d="M2 17l10 5 10-5M2 12l10 5 10-5"/>
      </svg>
    </div>
    <h1>SurfaceSense</h1>
    <p class="subtitle">Dashboard</p>

    <div class="form">
      <label>
        E-Mail
        <input
          type="email"
          bind:value={email}
          on:keydown={onKeydown}
          placeholder="deine@email.de"
          autocomplete="email"
        />
      </label>
      <label>
        Passwort
        <input
          type="password"
          bind:value={password}
          on:keydown={onKeydown}
          placeholder="••••••••"
          autocomplete="current-password"
        />
      </label>

      {#if error}
        <div class="error">{error}</div>
      {/if}

      <button class="btn-login" on:click={handleLogin} disabled={loading}>
        {#if loading}
          <span class="spinner"></span>
        {:else}
          Anmelden
        {/if}
      </button>
    </div>
  </div>
</div>

<style>
  .page {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100vh;
    background: #0d1117;
  }
  .card {
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 12px;
    padding: 40px 36px;
    width: 360px;
    text-align: center;
  }
  .logo { margin-bottom: 16px; }
  h1 { font-size: 22px; font-weight: 700; color: #e6edf3; margin-bottom: 4px; }
  .subtitle { font-size: 13px; color: #8b949e; margin-bottom: 32px; }

  .form { display: flex; flex-direction: column; gap: 16px; text-align: left; }
  label { display: flex; flex-direction: column; gap: 6px; font-size: 13px; color: #8b949e; }
  input {
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 8px;
    padding: 10px 12px;
    color: #e6edf3;
    font-size: 14px;
    outline: none;
    transition: border-color 0.15s;
  }
  input:focus { border-color: #2dd4bf; }

  .error {
    background: rgba(248,81,73,0.1);
    border: 1px solid rgba(248,81,73,0.3);
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 13px;
    color: #f85149;
  }

  .btn-login {
    background: #2dd4bf;
    color: #0d1117;
    border: none;
    border-radius: 8px;
    padding: 12px;
    font-size: 14px;
    font-weight: 700;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: opacity 0.15s;
  }
  .btn-login:hover:not(:disabled) { opacity: 0.9; }
  .btn-login:disabled { opacity: 0.5; cursor: not-allowed; }

  .spinner {
    width: 16px; height: 16px;
    border: 2px solid rgba(0,0,0,0.2);
    border-top-color: #0d1117;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
