package manifest

import (
	"path/filepath"
	"testing"
)

// The same fixtures the bash essentials are checked against.
func TestFixtures(t *testing.T) {
	root := filepath.Join("..", "..")
	valid, _ := filepath.Glob(filepath.Join(root, "tests", "fixtures", "valid-*.yaml"))
	valid = append(valid, filepath.Join(root, "zts.example.yaml"))
	for _, f := range valid {
		if _, err := Check(f); err != nil {
			t.Errorf("%s: expected ok, got %v", f, err)
		}
	}
	invalid, _ := filepath.Glob(filepath.Join(root, "tests", "fixtures", "invalid-*.yaml"))
	if len(invalid) == 0 {
		t.Fatal("no invalid fixtures found")
	}
	for _, f := range invalid {
		if _, err := Check(f); err == nil {
			t.Errorf("%s: expected failure", f)
		}
	}
}

func TestPresetsAreValid(t *testing.T) {
	for _, p := range PresetNames() {
		text, err := Preset(p)
		if err != nil {
			t.Fatal(err)
		}
		tmp := filepath.Join(t.TempDir(), p+".yaml")
		if err := writeFile(tmp, text); err != nil {
			t.Fatal(err)
		}
		m, err := Check(tmp)
		if err != nil {
			t.Fatalf("preset %s: %v", p, err)
		}
		if len(m.Profiles["isolated"].Allow) != 0 {
			t.Fatalf("preset %s: isolated must be empty", p)
		}
	}
}
