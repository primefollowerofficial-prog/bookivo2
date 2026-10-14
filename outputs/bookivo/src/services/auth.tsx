import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { requireSupabase, supabase, supabaseConfigured, supabaseConfigMessage } from './supabase';

type AuthValue = {
  session: Session | null; user: User | null; ready: boolean; isAdmin: boolean;
  signIn(email: string, password: string): Promise<void>;
  signUp(displayName: string, email: string, password: string): Promise<{ confirmationRequired: boolean }>;
  signOut(): Promise<void>; signInWithGoogle(): Promise<void>;
  sendPasswordReset(email: string): Promise<void>; updatePassword(password: string): Promise<void>;
};
const AuthContext = createContext<AuthValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(!supabaseConfigured);
  const [isAdmin, setIsAdmin] = useState(false);

  useEffect(() => {
    if (!supabase) return;
    const client = supabase;
    if (!client) return;
    let alive = true;
    const loadRole = async (user: User | null) => {
      if (!user) { if (alive) setIsAdmin(false); return; }
      const { data, error } = await client.from('profiles').select('role').eq('id', user.id).maybeSingle();
      if (alive) setIsAdmin(!error && data?.role === 'admin');
    };
    void client.auth.getSession().then(({ data }) => {
      if (!alive) return;
      setSession(data.session); setReady(true); void loadRole(data.session?.user ?? null);
    });
    const { data: subscription } = client.auth.onAuthStateChange((_event, next) => {
      setSession(next); setReady(true); void loadRole(next?.user ?? null);
    });
    return () => { alive = false; subscription.subscription.unsubscribe(); };
  }, []);

  const value = useMemo<AuthValue>(() => ({
    session, user: session?.user ?? null, ready, isAdmin,
    async signIn(email, password) {
      const { error } = await requireSupabase().auth.signInWithPassword({ email: email.trim(), password });
      if (error) throw error;
    },
    async signUp(displayName, email, password) {
      const { data, error } = await requireSupabase().auth.signUp({
        email: email.trim(), password, options: { data: { display_name: displayName.trim() }, emailRedirectTo: `${location.origin}/account` },
      });
      if (error) throw error;
      return { confirmationRequired: !data.session };
    },
    async signOut() {
      const { error } = await requireSupabase().auth.signOut(); if (error) throw error;
    },
    async signInWithGoogle() {
      const { error } = await requireSupabase().auth.signInWithOAuth({ provider: 'google', options: { redirectTo: `${location.origin}/account` } });
      if (error) throw error;
    },
    async sendPasswordReset(email) {
      const { error } = await requireSupabase().auth.resetPasswordForEmail(email.trim(), { redirectTo: `${location.origin}/reset-password` });
      if (error) throw error;
    },
    async updatePassword(password) {
      const { error } = await requireSupabase().auth.updateUser({ password }); if (error) throw error;
    },
  }), [session, ready, isAdmin]);

  return <AuthContext.Provider value={value}>{!supabaseConfigured && <div className="backend-alert" role="status">{supabaseConfigMessage}</div>}{children}</AuthContext.Provider>;
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}
