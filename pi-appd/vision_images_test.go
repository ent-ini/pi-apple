package main

import "testing"

func TestIsHEICImageRecognizesMIMEAndExtension(t *testing.T) {
	for _, test := range []struct {
		path, mime string
		want       bool
	}{
		{"photo.HEIC", "", true},
		{"photo.bin", "image/heif", true},
		{"photo.jpg", "image/jpeg", false},
	} {
		if got := isHEICImage(test.path, test.mime); got != test.want {
			t.Fatalf("isHEICImage(%q, %q) = %v, want %v", test.path, test.mime, got, test.want)
		}
	}
}
