<?php
declare(strict_types=1);
/** Draws Developer's brand images with GD (the logo, the abbreviated mark, the favicon, the PWA icons): php bin/make_brand_images.php. Rerun after changing the mark. */
$dir = dirname(__DIR__) . '/html/assets/images';
$font = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf';
$indigo = [52, 73, 160];                                         // Developer's blue (the variable keeps the kit's name)
function mark(int $size, bool $rounded = true): GdImage
{
    global $indigo;
    $im = imagecreatetruecolor($size, $size);
    imagesavealpha($im, true);
    imagealphablending($im, false);
    imagefill($im, 0, 0, imagecolorallocatealpha($im, 0, 0, 0, 127));
    imagealphablending($im, true);
    $bg = imagecolorallocate($im, ...$indigo);
    $r = $rounded ? (int) round($size * 0.22) : 0;
    imagefilledrectangle($im, $r, 0, $size - 1 - $r, $size - 1, $bg);
    imagefilledrectangle($im, 0, $r, $size - 1, $size - 1 - $r, $bg);
    foreach ([[$r, $r], [$size - 1 - $r, $r], [$r, $size - 1 - $r], [$size - 1 - $r, $size - 1 - $r]] as [$cx, $cy]) {
        imagefilledellipse($im, $cx, $cy, $r * 2, $r * 2, $bg);
    }
    // a database: a white cylinder with two bands — the tool's subject
    $white = imagecolorallocate($im, 255, 255, 255);
    $w = (int) round($size * 0.56); $cx = (int) round($size / 2);
    $eh = (int) max(4, round($size * 0.16));                         // an ellipse's height
    $top = (int) round($size * 0.24); $bot = $size - 1 - $top;       // the cylinder's top and bottom centres
    imagefilledrectangle($im, $cx - intdiv($w, 2), $top, $cx + intdiv($w, 2), $bot, $white);
    imagefilledellipse($im, $cx, $bot, $w, $eh, $white);
    imagefilledellipse($im, $cx, $top, $w, $eh, $white);
    $t = max(1, (int) round($size * 0.035));
    imagesetthickness($im, $t);
    imageellipse($im, $cx, $top, $w - 2 * $t, $eh - 2 * $t, $bg);   // the top rim
    foreach ([0.38, 0.70] as $f) {                                   // two bands, as arcs across the front
        imagearc($im, $cx, (int) round($top + ($bot - $top) * $f), $w - 2 * $t, $eh, 0, 180, $bg);
    }
    imagesetthickness($im, 1);
    return $im;
}
foreach (['favicon.png' => 64, 'logo-abbr.png' => 128, 'apple-touch-icon.png' => 180, 'icon-192.png' => 192, 'icon-512.png' => 512] as $file => $size) {
    $im = mark($size, $file !== 'apple-touch-icon.png');
    if ($file === 'apple-touch-icon.png') {                                   // iOS rounds it itself: an opaque square
        $flat = imagecreatetruecolor($size, $size);
        imagefill($flat, 0, 0, imagecolorallocate($flat, ...$indigo));
        imagecopy($flat, $im, 0, 0, 0, 0, $size, $size);
        $im = $flat;
    }
    imagepng($im, $dir . '/' . $file);
}
// the full logo: the mark and the name
$w = 420; $h = 90;
$im = imagecreatetruecolor($w, $h);
imagesavealpha($im, true);
imagealphablending($im, false);
imagefill($im, 0, 0, imagecolorallocatealpha($im, 0, 0, 0, 127));
imagealphablending($im, true);
$m = mark(70);
imagecopy($im, $m, 4, 10, 0, 0, 70, 70);
$dark = imagecolorallocate($im, 33, 37, 41);
imagettftext($im, 21, 0, 86, 55, $dark, $font, 'Developer');
imagepng($im, $dir . '/logo-full.png');
echo "brand images drawn in $dir\n";
