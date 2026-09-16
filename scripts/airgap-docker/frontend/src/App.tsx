import { Button } from "./components/ui/button";

export function App() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-950 text-slate-50">
      <section className="space-y-6 rounded-xl border border-slate-800 bg-slate-900 p-10 shadow-2xl">
        <h1 className="text-3xl font-semibold tracking-tight">Air-gap React</h1>
        <p className="text-slate-300">shadcn/uiとTailwind CSSをlocal資材だけでbuildしました。</p>
        <Button>検証完了</Button>
      </section>
    </main>
  );
}
