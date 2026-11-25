"""Compare the actual compiled .NET catalog with the existing Python catalog.
No database access, no migration execution, no external Python dependencies.
"""
import ast
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    tree = ast.parse((ROOT / "radius/migrate.py").read_text(encoding="utf-8"))
    assignments = [node for node in tree.body if isinstance(node, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "MIGRATIONS" for t in node.targets)]
    if len(assignments) != 1:
        raise RuntimeError("Legacy migration catalog not uniquely defined")
    catalog = ast.literal_eval(assignments[0].value)
    expected = []
    for version, name, objects in catalog:
        digest = hashlib.sha256((ROOT / "database" / name).read_bytes()).hexdigest()
        expected.append("\t".join((str(version), name, digest, "|".join(objects))))
    actual = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if actual != expected or len(actual) != 10:
        raise SystemExit("C# migration catalog parity failed")
    print("C# migration catalog parity PASS: 10 versions, exact SHA-256 and object order")


if __name__ == "__main__":
    main()
