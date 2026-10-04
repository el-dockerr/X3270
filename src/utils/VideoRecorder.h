#pragma once
#include <string>
#include <functional>

namespace x3270 {

class VideoRecorder {
public:
    VideoRecorder();
    ~VideoRecorder();

    // Start the recording specifying the resolution (width and height)
    bool startRecording(const std::string& filePath, int width, int height);
    
    // Insert a frame (we will pass the CGImageRef as a void* pointer)
    void appendFrame(void* cgImageRef);
    
    // Stop the recording asynchronously
    void stopRecording(std::function<void()> completion);
    
    bool isRecording() const;

private:
    void* impl_; // Opaque pointer to the Objective-C object (DXAVRecorder)
};

} // namespace x3270