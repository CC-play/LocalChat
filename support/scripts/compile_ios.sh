# UNCOMMENT THESE LINES TO BUILD FROM LATEST COMMIT
# git reset --hard origin/main
# git pull

cd app
fvm flutter clean
fvm flutter pub get
fvm flutter precache --ios
(
	cd ios
	pod update
)
fvm flutter build ipa
if [ -f build/ios/ipa/Runner.ipa ]; then
	mv build/ios/ipa/Runner.ipa build/ios/ipa/LocalChat.ipa
fi
cd ..