package manifest

import "os"

func writeFile(path, text string) error { return os.WriteFile(path, []byte(text), 0o644) }
