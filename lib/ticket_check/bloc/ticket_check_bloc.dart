import 'dart:async';
import 'dart:convert';
import 'package:bloc/bloc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:conferenceapp/common/logger.dart';
import 'package:conferenceapp/model/ticket.dart';
import './bloc.dart';

class TicketCheckBloc extends Bloc<TicketCheckEvent, TicketCheckState> {
  final ticketCollection = Firestore.instance.collection('tickets');
  final checkedTickets = Firestore.instance.collection('tickets_checked');
  final users = Firestore.instance.collection('users');

  @override
  String toString() => 'TicketCheckBloc';

  @override
  TicketCheckState get initialState => NoTicketCheckState();

  @override
  Stream<TicketCheckState> mapEventToState(
    TicketCheckEvent event,
  ) async* {
    if (event is InitEvent) {
      yield NoTicketCheckState();
    }
    if (event is TicketScanned) {
      yield* handleTicketScanned(event);
    }

    if (event is TickedValidated) {
      yield* handleTicketValidated(event);
    }
  }

  Stream<TicketCheckState> handleTicketValidated(TickedValidated event) async* {
    try {
      yield LoadingState();
      final user = users.document(event.userId);
      await user.setData(
        {
          'ticketId': event.ticket.ticketId,
          'orderId': event.ticket.orderId,
          'updated': DateTime.now(),
        },
        merge: true,
      );

      await checkedTickets.document(event.ticket.ticketId).setData({
        'userId': event.userId,
        'ticketId': event.ticket.ticketId,
        'orderId': event.ticket.orderId,
        'updated': DateTime.now(),
      });

      yield TicketValidatedState(event.ticket, event.userId);
    } catch (e) {
      logger.errorException(e);
      yield TicketErrorState('Error during marking as present.');
    }
  }

  Stream<TicketCheckState> handleTicketScanned(TicketScanned event) async* {
    yield LoadingState();
    try {
      final values = event.valueRead.split(' ');
      final userId = values[0];
      final orderId =
          values[1].contains('OT') ? values[1].substring(2) : values[1];
      final ticketId = values[2];
      final matchingTickets = await getMatchingTickets(orderId, ticketId);

      if (matchingTickets.length > 0) {
        final matchingCheckedTicketsSnapshot = await checkedTickets
            .where(
              'ticketId',
              whereIn: matchingTickets.map((f) => f['ticketId']).toList(),
            )
            .getDocuments();
        final matchingCheckedTickets = matchingCheckedTicketsSnapshot.documents;
        if (matchingCheckedTickets.length == matchingTickets.length) {
          yield TicketErrorState(
              'Wszystkie bilety z zamówienia $orderId zostały już sprawdzone. W zamówieniu było ${matchingTickets.length} biletów. Skonsultuj sytuację z osobą odpowiedzialną za sprawdzanie biletów.');
          return;
        }
        final matchingTicketsWithoutChecked = List();

        matchingTickets.forEach((n) {
          if (matchingCheckedTickets.firstWhere(
                  (m) => m['ticketId'] == n['ticketId'],
                  orElse: () => null) ==
              null) matchingTicketsWithoutChecked.add(n);
        });

        final selectedTicket = matchingTicketsWithoutChecked.first;

        logger.info(selectedTicket.toString());

        final matchingOrderId = selectedTicket['orderId'];
        final matchingTicketId = selectedTicket['ticketId'];
        final matchingEmail = selectedTicket['email'];
        final matchingName = selectedTicket['name'];
        final matchingType = selectedTicket['type'];

        final name = utf8.decode(base64Decode(matchingName));
        yield TicketScannedState(
          Ticket(matchingOrderId, matchingTicketId),
          userId,
          name,
          matchingType == 'Student',
          matchingTickets.length,
          matchingTicketsWithoutChecked.length,
          selectedTicket['used'],
        );
      } else {
        yield TicketErrorState(
            'Brak biletów o numerze zamówienia: $orderId lub biletu: $ticketId.');
      }
    } catch (e) {
      logger.errorException(e);
      yield TicketErrorState(
          'Wystąpił problem z odczytaniem lub znalezieniem pasujacego biletu. Spróbuj ponownie.');
    }
  }

  Future<List> getMatchingTickets(String orderId, String ticketId) async {
    final ticketCollection = await getTicketsCollection();

    final checkByOrder = isCheckedByOrder(orderId);
    final matchigTickets = ticketCollection
        .where(checkByOrder
            ? (t) => t['orderId'] == orderId
            : (t) => t['ticketId'] == ticketId)
        .toList();
    return matchigTickets;
  }

  bool isCheckedByOrder(String orderId) {
    return orderId.length > 1;
  }

  Future<List> getTicketsCollection() async {
    final tickets =
        await Firestore.instance.document('tickets/tickets').snapshots().first;

    final List ticketCollection = tickets.data['tickets'];
    return ticketCollection;
  }

  @override
  Future<void> close() {
    return super.close();
  }
}
