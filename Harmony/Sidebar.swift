//
//  Sidebar.swift
//  Harmony
//
//  Created by Geri Doe on 8/7/22.
//

import SwiftUI

var secondaryColor: Color =
Color(.init(
    red: 0 / 255,
    green: 0 / 255,
    blue: 0 / 255,
    alpha: 1))

struct MenuItem: Identifiable {
    var id: Int
    var icon: String
    var text: String
}

var userActions: [MenuItem] = [
    MenuItem(id: 4001, icon: "person.circle.fill", text: "My Account"),
    MenuItem(id: 4002, icon: "wifi.circle", text: "Spotify"),
    MenuItem(id: 4003, icon: "applelogo", text: "Apple Music")
]

var profileActions : [MenuItem] = [
    MenuItem(id: 4004, icon: "wrench.and.screwdriver.fill", text: "Settings"),
    MenuItem(id: 4005, icon: "iphone.and.arrow.forward", text: "Logout")
]

struct Sidebar: View {
    @Binding var sidebarVisible: Bool
    var sidebarWdith = UIScreen.main.bounds.size.width * 0.7
    var bgColor: Color =
    Color(.init(
        red: 100 / 255,
        green: 7 / 255,
        blue: 182 / 255,
        alpha: 1))
    
    var body: some View {
        ZStack {
            GeometryReader { _ in
                EmptyView()
            }
            .background(.gray.opacity(0.6))
            .opacity(sidebarVisible ? 1 : 0)
            .animation(.easeInOut.delay(0.2), value: sidebarVisible)
            .onTapGesture {
                sidebarVisible.toggle()
            }
            content
        }
        .edgesIgnoringSafeArea(.all)
       /* if sidebarVisible {
            Text("Sidebar visible")
                .bold()
                .font(.largeTitle)
                .background(.purple)
        } */
    }
    
    var content: some View {
        HStack(alignment: .top) {
            ZStack(alignment: .top) {
            bgColor
                
                VStack(alignment: .leading, spacing: 20) {
                    userProfile
                    Divider()
                    MenuLinks(items: userActions)
                    Divider()
                    MenuLinks(items: profileActions)
                }
                .padding(.top, 80)
                .padding(.horizontal, 40)
            }
            .frame(width: sidebarWdith)
            .offset(x: sidebarVisible ? 0: -sidebarWdith)
            .animation(.default, value: sidebarVisible)
            Spacer()
        }
    }
    var userProfile: some View {
        VStack(alignment: .leading) {
            HStack {
                AsyncImage(url: URL(string: "")) { image in image
                        .resizable()
                        .frame(width: 70, height: 70, alignment: .center)
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(.purple, lineWidth: 2)
                        }
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .frame(width: 35, height: 35, alignment: .center)
                        
                }
                .aspectRatio(3 / 2, contentMode: .fill)
                .shadow(radius: 4)
                .padding(.trailing, 18)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Geri Doe")
                        .foregroundColor(.white)
                        .bold()
                        .font(.title3)
                    Text(verbatim: "doegeri11@gmail.com")
                        .foregroundColor(secondaryColor)
                        .font(.caption)
                }
            }
            .padding(.bottom, 20)
        }
    }
}

struct MenuLinks: View {
    var items: [MenuItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(items) { item in
                menuLink(icon: item.icon, text: item.text)
            }
        }
        .padding(.vertical, 14)
        .padding(.leading, 8)
    }
}

struct menuLink: View {
    var icon: String
    var text: String
    var body: some View {
        HStack {
            Image(systemName: icon)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundColor(secondaryColor)
                .padding(.trailing, 18)
            Text(text)
                .foregroundColor(.white)
                .font(.body)
        }
        .onTapGesture {
            print("Tapped on \(text)")
        }
    }
}
/*struct Sidebar_Previews: PreviewProvider {
    static var previews: some View {
        Sidebar()
    }
} */
