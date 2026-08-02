//
//  AppleLibraryView.swift
//  Harmony
//
//  Created by Geri Doe on 12/20/22.
//

import SwiftUI
import MediaPlayer


class AppleLibraryView: UIViewController, MPMediaPickerControllerDelegate {
    
    @IBAction func LibraryAction(_sender: UIButton){
        let picker: MPMediaPickerController = MPMediaPickerController.self(mediaTypes: MPMediaType.music)
        picker.delegate = self
        picker.allowsPickingMultipleItems = true
        self.present(picker, animated: true, completion: nil)
        
    }
    
    func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
        self.dismiss(animated: true, completion: nil)
    }
    
    func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
        self.dismiss(animated: true, completion: nil)
        print("Selected:  \(mediaItemCollection)")
    }
}
