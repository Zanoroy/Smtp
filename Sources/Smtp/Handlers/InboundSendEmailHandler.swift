//
//  https://mczachurski.dev
//  Copyright © 2021 Marcin Czachurski and the repository contributors.
//  Licensed under the MIT License.
//

import NIO
import NIOSSL

internal final class InboundSendEmailHandler: ChannelInboundHandler {
    typealias InboundIn = SmtpResponse
    typealias OutboundOut = SmtpRequest

    enum Expect {
        case initialMessageFromServer
        case okAfterHello
        case okAfterStartTls
        case okAfterStartTlsHello
        case okAfterAuthBegin
        case okAfterUsername
        case okAfterPassword
        case okAfterMailFrom
        case okAfterRecipient
        case okAfterDataCommand
        case okAfterMailData
        case okAfterQuit
        case nothing

        case error
    }

    private var currentlyWaitingFor = Expect.initialMessageFromServer
    private var email: Email
    private let serverConfiguration: SmtpServerConfiguration
    private let allDonePromise: EventLoopPromise<Void>
    private var recipients: [EmailAddress] = []

    init(configuration: SmtpServerConfiguration, email: Email, allDonePromise: EventLoopPromise<Void>) {
        self.email = email
        self.allDonePromise = allDonePromise
        self.serverConfiguration = configuration

        if let to = self.email.to {
            self.recipients += to
        }

        if let cc = self.email.cc {
            self.recipients += cc
        }

        if let bcc = self.email.bcc {
            self.recipients += bcc
        }
    }

    func send(context: ChannelHandlerContext, command: SmtpRequest) {
        context.writeAndFlush(self.wrapOutboundOut(command)).cascadeFailure(to: self.allDonePromise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let result = self.unwrapInboundIn(data)
        switch result {
        case .error(let message):
            self.allDonePromise.fail(SmtpError(message))
            return
        case .ok:
            () // cool
        }

        switch self.currentlyWaitingFor {
        case .initialMessageFromServer:
            self.send(context: context,
                      command: .sayHello(serverName: self.serverConfiguration.hostname,
                                         helloMethod: self.serverConfiguration.helloMethod
                )
            )
            self.currentlyWaitingFor = .okAfterHello
        case .okAfterHello:

            if self.shouldInitializeTls() {
                self.send(context: context, command: .startTls)
                self.currentlyWaitingFor = .okAfterStartTls
            } else {
                switch self.serverConfiguration.signInMethod {
                case .credentials(_, _):
                    // self.send(context: context, command: .beginAuthentication)
                    self.send(context: context, command: .mailFrom(self.email.from.address))
                    self.currentlyWaitingFor = .okAfterAuthBegin
                case .anonymous:
                    self.send(context: context, command: .mailFrom(self.email.from.address))
                    self.currentlyWaitingFor = .okAfterMailFrom
                }
            }

        case .okAfterStartTls:
            self.send(context: context, command: .sayHelloAfterTls(serverName: self.serverConfiguration.hostname, helloMethod:  self.serverConfiguration.helloMethod))
            self.currentlyWaitingFor = .okAfterStartTlsHello
        case .okAfterStartTlsHello:
            self.send(context: context, command: .beginAuthentication)
            self.currentlyWaitingFor = .okAfterAuthBegin
        case .okAfterAuthBegin:
            
            switch self.serverConfiguration.signInMethod {
            case .credentials(let username, _):
                self.send(context: context, command: .authUser(username))
                self.currentlyWaitingFor = .okAfterUsername
            case .anonymous:
                self.allDonePromise.fail(SmtpError("After auth begin executed for anonymous sign in method"))
                break;
            }

        case .okAfterUsername:
            switch self.serverConfiguration.signInMethod {
            case .credentials(_, let password):
                self.send(context: context, command: .authPassword(password))
                self.currentlyWaitingFor = .okAfterPassword
            case .anonymous:
                self.allDonePromise.fail(SmtpError("After user name executed for anonymous sign in method"))
                break;
            }

        case .okAfterPassword:
            self.send(context: context, command: .mailFrom(self.email.from.address))
            self.currentlyWaitingFor = .okAfterMailFrom
        case .okAfterMailFrom:
            if let recipient = self.recipients.popLast() {
                self.send(context: context, command: .recipient(recipient.address))
            } else {
                fallthrough
            }
        case .okAfterRecipient:
            self.send(context: context, command: .data)
            self.currentlyWaitingFor = .okAfterDataCommand
        case .okAfterDataCommand:
            self.send(context: context, command: .transferData(email))
            self.currentlyWaitingFor = .okAfterMailData
        case .okAfterMailData:
            self.send(context: context, command: .quit)
            self.currentlyWaitingFor = .okAfterQuit
        case .okAfterQuit:
            self.allDonePromise.succeed(())
            self.currentlyWaitingFor = .nothing
        case .nothing:
            () // ignoring more data whilst quit (it's odd though)
        case .error:
            self.allDonePromise.fail(SmtpError("Communication error state"))
        }
    }

    private func shouldInitializeTls() -> Bool {
        return self.serverConfiguration.secure == .startTls || self.serverConfiguration.secure == .startTlsWhenAvailable
    }
}
