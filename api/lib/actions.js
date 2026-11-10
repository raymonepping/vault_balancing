// lib/actions.js: the drill as a sequence of console buttons (D16). Pure: the
// API shows the next step, and the host runner checks the same function before
// it runs anything, so a button can never run a step out of order (a second
// "kill Amsterdam" in the middle of a drill). Each step is the make target the
// terminal runs; Ansible and Vault still refuse a wrong state on their own.
// A step is done when its last journal line exists in the open drill.

// sites: config/sites.json's array. Returns the ordered steps.
export function steps(sites) {
  const by = (role) => sites.find((s) => s.role === role);
  const P = by('primary');
  const F = by('performance');
  const D = by('dr');
  return [
    { id: 'site-down', act: 'I', label: `${P.name} goes dark`, make: ['site-down', `SITE=${P.id}`], doneStep: 'front door marked it down', confirm: P.id },
    { id: 'promote', act: 'II', label: `Promote ${D.name}`, make: ['promote', `SITE=${D.id}`], doneStep: 'dr token' },
    { id: 'repoint', act: 'III', label: `Point ${F.name} at ${D.name}`, make: ['repoint', `SITE=${F.id}`, `TO=${D.id}`], doneStep: 'lag normal', doneAct: 'III' },
    { id: 'fence', act: 'IV', label: `Fence ${P.name}`, make: ['fence', `SITE=${P.id}`], doneStep: 'fenced' },
    { id: 'site-up', act: 'IV', label: `Bring ${P.name} back`, make: ['site-up', `SITE=${P.id}`], doneStep: 'site-up' },
    { id: 'demote', act: 'IV', label: `Demote ${P.name} under ${D.name}`, make: ['demote', `SITE=${P.id}`, `TO=${D.id}`], doneStep: 'streams as DR secondary' },
    { id: 'unfence', act: 'IV', label: `Unfence ${P.name}`, make: ['unfence', `SITE=${P.id}`], doneStep: 'unfenced' },
    { id: 'failback', act: 'V', label: `Fail back to ${P.name}`, make: ['failback'], doneStep: 'zero lost' },
    { id: 'report', act: 'Epilogue', label: 'Write the report', make: ['report'], doneStep: null },
  ];
}

const isDone = (step, lines) => step.doneStep !== null && lines.some((l) => l.step === step.doneStep && (!step.doneAct || l.act === step.doneAct));

// The next step of the drill: with no open drill, the first one (it opens a
// drill); otherwise the first step whose closing line is not in the journal.
export function nextStep(sites, drill) {
  const all = steps(sites);
  if (!drill) return all[0];
  return all.find((s) => !isDone(s, drill.lines ?? [])) ?? all[all.length - 1];
}

// What a person may do with it, and why not.
export function view(step, { role, running }) {
  const allowed = role === 'admin' || role === 'operator';
  const reason = !role ? 'Sign in as an operator to run the drill from here.' : !allowed ? 'Operators and admins run the drill; you are a viewer.' : running ? `Running: ${running.action}` : null;
  return { id: step.id, act: step.act, label: step.label, command: `make ${step.make.join(' ')}`, confirm: step.confirm ?? null, enabled: allowed && !running, reason };
}
