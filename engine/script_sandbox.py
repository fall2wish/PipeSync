import json
import subprocess
from typing import Dict, Any, List, Optional

class ScriptExecutionResult:
    def __init__(self, is_success: bool, transformed_plan: List[Dict[str, str]], execution_error: Optional[str] = None):
        self.is_success = is_success
        self.transformed_plan = transformed_plan
        self.execution_error = execution_error

    @classmethod
    def success(cls, plan: List[Dict[str, str]]) -> 'ScriptExecutionResult':
        return cls(True, plan, None)

    @classmethod
    def failure(cls, error: str) -> 'ScriptExecutionResult':
        return cls(False, [], error)

class ScriptSandbox:
    MAX_MEMORY_MB = 16

    def run_pre_hook(self, script_source: str, execution_context: Dict[str, Any], timeout_ms: int = 5000) -> ScriptExecutionResult:
        context_json = json.dumps(execution_context)

        js_code = f"""
const crypto = require('crypto');

const PipeContext = {context_json};
PipeContext.utils = {{
    log: function(msg) {{}},
    warn: function(msg) {{}},
    sha256: function(str) {{
        return crypto.createHash('sha256').update(str).digest('hex');
    }},
    formatDate: function(ts, pattern) {{
        const d = new Date(ts);
        const yyyy = d.getUTCFullYear();
        const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
        const dd = String(d.getUTCDate()).padStart(2, '0');
        if (pattern === 'yyyy-MM-dd') {{
            return yyyy + '-' + mm + '-' + dd;
        }}
        return d.toISOString();
    }}
}};

try {{
    const result = eval({json.dumps(script_source)});
    if (!Array.isArray(result)) {{
        process.stdout.write(JSON.stringify({{ error: 'Hook script must return an array' }}));
        process.exit(0);
    }}
    process.stdout.write(JSON.stringify({{ success: true, plan: result }}));
}} catch (e) {{
    process.stdout.write(JSON.stringify({{ error: e.toString() }}));
}}
"""
        timeout_sec = timeout_ms / 1000.0

        try:
            cmd = ['node', f'--max-old-space-size={self.MAX_MEMORY_MB}', '-e', js_code]
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_sec
            )
            if proc.returncode != 0 and not proc.stdout:
                return ScriptExecutionResult.failure(f'Process crashed: {proc.stderr.strip()}')

            resp = json.loads(proc.stdout)
            if 'error' in resp:
                return ScriptExecutionResult.failure(resp['error'])

            plan = []
            for item in resp.get('plan', []):
                plan.append({
                    'sourcePath': str(item.get('sourcePath', '')),
                    'targetRelativePath': str(item.get('targetRelativePath', ''))
                })
            return ScriptExecutionResult.success(plan)

        except subprocess.TimeoutExpired:
            return ScriptExecutionResult.failure(f'Execution timeout exceeded {timeout_ms} ms')
        except Exception as e:
            return ScriptExecutionResult.failure(str(e))

    def release(self):
        pass
